import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'g3_vas_sealed_invitation.dart';

const g3VasHost = 'talx.opslinx.de';
final _deviceId = RegExp(r'^[A-Za-z0-9_-]{6,40}$');
final _room = RegExp(r'^(?:[0-9]{10}|[a-f0-9]{32})$');
final _invitationId = RegExp(r'^[A-Za-z0-9_-]{24}$');
final _protectedRoomKey = RegExp(r'^vasKey=[A-Za-z0-9_-]{43}$');

String? g3RoomFromHandyLink(Uri uri) {
  final parts = uri.pathSegments;
  if (uri.scheme != 'https' ||
      uri.host != g3VasHost ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.hasQuery ||
      (uri.hasFragment && !_protectedRoomKey.hasMatch(uri.fragment)) ||
      parts.length != 3 ||
      parts[0] != 'vas' ||
      parts[1] != 'join' ||
      !_room.hasMatch(parts[2])) {
    return null;
  }
  return parts[2];
}

Future<bool> g3OpenVideoHelp(Uri uri) async =>
    await const MethodChannel('mChannel')
        .invokeMethod<bool>('g3_open_video_help', uri.toString()) ==
    true;

class G3VasInbox extends ChangeNotifier {
  G3VasInbox(this._sign, this._registerIdentity,
      {http.Client Function()? newClient})
      : _newClient = newClient ?? http.Client.new;

  final String Function(String) _sign;
  final VoidCallback _registerIdentity;
  final http.Client Function() _newClient;
  Timer? _timer;
  http.Client? _client;
  String _id = '';
  String? _token;
  String? _keyCertificate;
  G3VasInviteKey? _key;
  DateTime? _refreshBy;
  String? _pending;
  String? _lastHandled;
  Uri? _linkRoom;
  bool _busy = false;

  bool get hasInvitation => _pending != null || _linkRoom != null;
  bool get busy => _busy;

  void setForeground(bool active, String id) {
    final valid = active && _deviceId.hasMatch(id);
    if (valid && _client != null && _id == id) return;
    if (!valid && _client == null) return;
    _timer?.cancel();
    _client?.close();
    _client = null;
    _token = null;
    _keyCertificate = null;
    _key = null;
    _pending = null;
    _busy = false;
    _id = id;
    if (valid) {
      final client = _newClient();
      _client = client;
      _schedule(client, Duration.zero);
    }
    notifyListeners();
  }

  void receiveLink(Uri? uri) {
    final room = uri == null ? null : g3RoomFromHandyLink(uri);
    if (room == null) return;
    _linkRoom = Uri.https(g3VasHost, '/vas/', {'room': room})
        .replace(fragment: uri!.hasFragment ? uri.fragment : null);
    notifyListeners();
  }

  Future<http.Response> _post(
      http.Client client, Uri uri, Map<String, String> data,
      {String? token}) async {
    final request = http.Request('POST', uri)
      ..followRedirects = false
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(data);
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    return client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 8));
  }

  Map<String, dynamic> _json(http.Response response) {
    if (response.statusCode != 200) throw const FormatException('VAS request');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  void _schedule(http.Client client, Duration delay) {
    if (_client != client) return;
    _timer = Timer(delay, () => unawaited(_poll(client)));
  }

  Future<void> _poll(http.Client client) async {
    var retry = const Duration(seconds: 6);
    try {
      if (_busy) return;
      if (_token == null || !DateTime.now().isBefore(_refreshBy!)) {
        final uri = Uri.https('linx.g3nx.net', '/client-vas-inbox');
        final id = _id;
        final key = _key ?? await G3VasInviteKey.create();
        if (_client != client) return;
        _key = key;
        final first = _json(await _post(client, uri, {
          'id': id, 'invite_key': key.publicKey, 'purpose': 'vas',
        }));
        if (_client != client) return;
        final challenge = first['challenge'] as String;
        final nonce = first['nonce'] as String;
        if (challenge.isEmpty ||
            challenge.length > 512 ||
            !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(nonce)) return;
        final signature = _sign('g3-bootstrap-v1:$id:$nonce');
        if (signature.isEmpty) return;
        final proof = await _post(client, uri,
            {'id': id, 'challenge': challenge, 'signature': signature});
        if (_client != client) return;
        if (proof.statusCode == 403) _registerIdentity();
        final verified = _json(proof);
        _token = verified['token'] as String;
        _keyCertificate = verified['key_certificate'] as String;
        _refreshBy = DateTime.now().add(const Duration(minutes: 4));
      }
      final response = await _post(
          client, Uri.https(g3VasHost, '/vas/inbox'),
          {'key_certificate': _keyCertificate!},
          token: _token);
      if (_client != client || _busy) return;
      if (response.statusCode == 401) _token = null;
      final id = _json(response)['invitation'];
      final value =
          id is String && id != _lastHandled && _invitationId.hasMatch(id)
              ? id
              : null;
      if (value != _pending) {
        _pending = value;
        notifyListeners();
      }
    } catch (_) {
      retry = const Duration(seconds: 15);
    } finally {
      _schedule(client, retry);
    }
  }

  Future<Uri?> respond(bool join) async {
    final linked = _linkRoom;
    if (linked != null) {
      _linkRoom = null;
      notifyListeners();
      return join ? linked : null;
    }
    final client = _client;
    final id = _pending;
    final key = _key;
    final device = _id;
    if (client == null || id == null || key == null || _busy) return null;
    _busy = true;
    notifyListeners();
    try {
      final result = _json(await _post(
          client,
          Uri.https(g3VasHost, '/vas/inbox'),
          {'invitation': id, 'decision': join ? 'join' : 'decline'},
          token: _token));
      if (_client != client) return null;
      _lastHandled = id;
      final room = result['room'];
      if (join && room is String && _room.hasMatch(room)) {
        final secret = await key.open(device: device, code: room,
            envelope: result['sealed'] as Map<String, dynamic>);
        if (_client != client) return null;
        return Uri.https(g3VasHost, '/vas/', {'room': room})
            .replace(fragment: 'vasKey=$secret');
      }
      return null;
    } finally {
      if (_client == client) {
        _pending = null;
        _busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client?.close();
    _client = null;
    super.dispose();
  }
}
