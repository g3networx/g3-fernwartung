import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/g3_vas_inbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

  test('Foreground invite requires approval and pauses in background', () async {
    final calls = <Map<String, dynamic>>[];
    final nonce = 'a' * 43;
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
              return http.Response(
                  jsonEncode(body.length == 1
                      ? {'challenge': 'signed-envelope', 'nonce': nonce}
                      : {'token': 'verified-token'}),
                  200);
            }
            expect(request.url.host, g3VasHost);
            expect(request.headers['authorization'], 'Bearer verified-token');
            return http.Response(
                jsonEncode(body.isEmpty
                    ? {'invitation': 'A' * 24}
                    : {'room': '2345678901'}),
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
    expect(await inbox.respond(true), '2345678901');
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
    final link = Uri.https(g3VasHost, '/vas/join/3456789012');
    inbox.receiveLink(link);
    expect(inbox.hasInvitation, isTrue);
    expect(await inbox.respond(false), isNull);
    expect(inbox.hasInvitation, isFalse);
    inbox.receiveLink(link);
    expect(await inbox.respond(true), '3456789012');
    inbox.dispose();
  });
}
