import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class G3AddressBookExpired implements Exception {}

class G3AddressBookRequestError implements Exception {
  final int status;
  G3AddressBookRequestError(this.status);
  @override
  String toString() => status == 409
      ? 'Das Adressbuch ist nicht leer oder kann nicht gelöscht werden.'
      : status == 403 || status == 404
          ? 'Keine Berechtigung oder der Eintrag ist nicht mehr verfügbar.'
          : status == 400
              ? 'Bitte die Eingaben prüfen.'
              : 'Adressbuch-Anfrage fehlgeschlagen. Bitte erneut versuchen.';
}

class G3AddressBookApi {
  String? token;
  final http.Client client;
  G3AddressBookApi({http.Client? client}) : client = client ?? http.Client();

  static String verifier() => base64Url
      .encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');

  Future<Map<String, dynamic>> request(String path,
      {Map<String, dynamic>? body}) async {
    final req = http.Request(body == null ? 'GET' : 'POST',
        Uri.https('rust.g3nx.net', '/client-addressbook/$path'))
      ..followRedirects = false
      ..headers['Accept'] = 'application/json'
      ..headers['X-G3-Native'] = '1';
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final response =
        await client.send(req).timeout(const Duration(seconds: 15));
    if (response.statusCode == 401) {
      await response.stream.drain<void>();
      throw G3AddressBookExpired();
    }
    if (response.statusCode != 200 && response.statusCode != 202) {
      await response.stream.drain<void>();
      throw G3AddressBookRequestError(response.statusCode);
    }
    final bytes = <int>[];
    await for (final chunk
        in response.stream.timeout(const Duration(seconds: 15))) {
      bytes.addAll(chunk);
      if (bytes.length > 4 * 1024 * 1024) throw Exception('Adressbuch zu groß');
    }
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> start(String verifier) =>
      request('login/start', body: {
        'challenge': base64Url
            .encode(sha256.convert(utf8.encode(verifier)).bytes)
            .replaceAll('=', '')
      });
  void close() => client.close();
}
