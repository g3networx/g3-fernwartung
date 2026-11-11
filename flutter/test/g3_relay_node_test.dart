import 'dart:io';

import 'package:flutter_hbb/g3_relay_node.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('matches the actual IPv4 endpoint and its mapped forms', () async {
    Future<List<InternetAddress>> lookup(String name) async => [
          if (name == 'opslinx02.g3nx.net') InternetAddress('192.0.2.7'),
          if (name == 'rust.g3nx.net') InternetAddress('192.0.2.1'),
        ];
    for (final ip in ['192.0.2.7', '::ffff:c000:207', '64:ff9b::c000:207']) {
      expect(await g3RelayNodeFor(ip, lookup: lookup), 2);
    }
    expect(await g3RelayNodeFor('192.0.2.42', lookup: lookup), isNull);
  });

  test('a shared DNS address does not identify a relay node', () async {
    final address = InternetAddress('2001:0db8:0:0::7');
    expect(
      await g3RelayNodeFor('2001:db8::7',
          lookup: (name) async =>
              name == 'opslinx03.g3nx.net' ? [address] : []),
      3,
    );
    expect(
      await g3RelayNodeFor('2001:db8::7',
          lookup: (_) async => [address]),
      isNull,
    );
  });
}
