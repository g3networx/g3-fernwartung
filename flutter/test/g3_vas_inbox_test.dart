import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_hbb/g3_vas_inbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _key(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

Future<Map<String, String>> _seal(String recipient, List<int> secret) async {
  final algorithm = X25519();
  final sender = await algorithm.newKeyPair();
  final public = _key((await sender.extractPublicKey()).bytes);
  final aad = utf8.encode(
      jsonEncode(['123456789', 'vas', '2345678901', recipient, public]));
  final shared = await algorithm.sharedSecretKey(
    keyPair: sender,
    remotePublicKey: SimplePublicKey(
        base64Url.decode(base64Url.normalize(recipient)),
        type: KeyPairType.x25519),
  );
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared, nonce: utf8.encode('OpsTalX/invite/v1'), info: aad);
  final box =
      await AesGcm.with256bits().encrypt(secret, secretKey: key, aad: aad);
  return {
    'pub': public,
    'iv': _key(box.nonce),
    'box': _key([...box.cipherText, ...box.mac.bytes]),
    'recipientKey': recipient,
  };
}

void main() {
  test('Only the verified guest link carries a room', () {
    expect(
        g3RoomFromHandyLink(
            Uri.parse('https://talx.opslinx.de/vas/join/1234567890')),
        '1234567890');
    for (final value in [
      'http://talx.opslinx.de/vas/join/1234567890',
      'https://talx.opslinx.de.evil.example/vas/join/1234567890',
      'https://talx.opslinx.de/vas/join/1234567890?redirect=x',
      'https://talx.opslinx.de/vas/join/1234567890#jwt=bad',
      'https://talx.opslinx.de/vas/launch#grant=bad',
      'https://talx.opslinx.de:444/vas/join/1234567890',
    ]) {
      expect(g3RoomFromHandyLink(Uri.parse(value)), isNull);
    }
  });

  test('Foreground invite requires approval and pauses in background',
      () async {
    final calls = <Map<String, dynamic>>[];
    final nonce = 'a' * 43;
    final secret = List<int>.generate(32, (i) => i);
    String? recipient;
    final inbox = G3VasInbox(
        (challenge) {
          expect(challenge, 'g3-bootstrap-v1:123456789:$nonce');
          return 'proof';
        },
        () => fail('Known identity must not register again'),
        newClient: () {
          return MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            calls.add(body);
            if (request.url.host == 'linx.g3nx.net') {
              if (body.containsKey('invite_key')) {
                expect(body['purpose'], 'vas');
                recipient = body['invite_key'] as String;
                return http.Response(
                    jsonEncode(
                        {'challenge': 'signed-envelope', 'nonce': nonce}),
                    200);
              }
              return http.Response(
                  jsonEncode({
                    'token': 'verified-token',
                    'key_certificate': 'verified-certificate',
                  }),
                  200);
            }
            expect(request.url.host, g3VasHost);
            expect(request.headers['authorization'], 'Bearer verified-token');
            return http.Response(
                jsonEncode(body['key_certificate'] == 'verified-certificate'
                    ? {'invitation': 'A' * 24}
                    : {
                        'room': '2345678901',
                        'sealed': await _seal(recipient!, secret)
                      }),
                200);
          });
        });
    final arrived = Completer<void>();
    inbox.addListener(() {
      if (inbox.hasInvitation && !arrived.isCompleted) arrived.complete();
    });
    inbox.setForeground(false, '123456789');
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
    inbox.setForeground(true, '123456789');
    await arrived.future.timeout(const Duration(seconds: 2));
    expect(inbox.hasInvitation, isTrue);
    expect(calls.length, 3);
    final accepted = await inbox.respond(true);
    expect(accepted?.queryParameters, {'room': '2345678901'});
    expect(accepted?.fragment, 'vasKey=${_key(secret)}');
    expect(calls.last, {'invitation': 'A' * 24, 'decision': 'join'});
    expect(inbox.hasInvitation, isFalse);
    inbox.setForeground(false, '123456789');
    await Future<void>.delayed(Duration.zero);
    expect(calls.length, 4);
    inbox.dispose();
  });

  test('Handy links also wait for an explicit decision', () async {
    final inbox = G3VasInbox((_) => '', () {},
        newClient: () => throw StateError('not needed'));
    final key = _key(List<int>.filled(32, 65));
    final link = Uri.https(g3VasHost, '/vas/join/3456789012')
        .replace(fragment: 'vasKey=$key');
    inbox.receiveLink(link);
    expect(inbox.hasInvitation, isTrue);
    expect(await inbox.respond(false), isNull);
    expect(inbox.hasInvitation, isFalse);
    inbox.receiveLink(link);
    final accepted = await inbox.respond(true);
    expect(accepted?.queryParameters, {'room': '3456789012'});
    expect(accepted?.fragment, 'vasKey=$key');
    inbox.dispose();
  });
}
