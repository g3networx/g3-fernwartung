import 'dart:convert';

import 'package:cryptography/cryptography.dart';

final _rawKey = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _code = RegExp(r'^[0-9]{10}$');
final _device = RegExp(r'^[A-Za-z0-9_-]{6,40}$');

String _urlKey(List<int> value) => base64UrlEncode(value).replaceAll('=', '');
List<int> _decode(String value) => base64Url.decode(base64Url.normalize(value));

class G3VasInviteKey {
  final SimpleKeyPair _pair;
  final String publicKey;

  G3VasInviteKey._(this._pair, this.publicKey);

  static Future<G3VasInviteKey> create() async {
    final pair = await X25519().newKeyPair();
    return G3VasInviteKey._(
        pair, _urlKey((await pair.extractPublicKey()).bytes));
  }

  Future<String> open({
    required String device,
    required String code,
    required Map<String, dynamic> envelope,
  }) async {
    final remote = envelope['pub'];
    final iv = envelope['iv'];
    final box = envelope['box'];
    if (!_device.hasMatch(device) ||
        !_code.hasMatch(code) ||
        envelope['recipientKey'] != publicKey ||
        remote is! String ||
        !_rawKey.hasMatch(remote) ||
        iv is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{16}$').hasMatch(iv) ||
        box is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{64}$').hasMatch(box)) {
      throw const FormatException('Invalid protected invitation.');
    }
    final aad =
        utf8.encode(jsonEncode([device, 'vas', code, publicKey, remote]));
    final seed = await X25519().sharedSecretKey(
      keyPair: _pair,
      remotePublicKey:
          SimplePublicKey(_decode(remote), type: KeyPairType.x25519),
    );
    if ((await seed.extractBytes()).every((byte) => byte == 0)) {
      throw const FormatException('Invalid invitation key.');
    }
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: seed, nonce: utf8.encode('OpsTalX/invite/v1'), info: aad);
    final raw = _decode(box);
    final clear = await AesGcm.with256bits().decrypt(
      SecretBox(raw.sublist(0, 32),
          nonce: _decode(iv), mac: Mac(raw.sublist(32))),
      secretKey: key,
      aad: aad,
    );
    return _urlKey(clear);
  }
}
