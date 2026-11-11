import 'dart:io';
import 'dart:typed_data';

Future<int?> g3RelayNodeFor(String endpoint,
    {Future<List<InternetAddress>> Function(String) lookup =
        InternetAddress.lookup}) async {
  final peer = InternetAddress.tryParse(endpoint);
  if (peer == null) return null;
  const nodes = {
    1: 'rust.g3nx.net',
    2: 'opslinx02.g3nx.net',
    3: 'opslinx03.g3nx.net'
  };
  final peerAddress = _canonicalAddress(peer);
  final matches = await Future.wait(nodes.entries.map((node) async {
    try {
      final addresses =
          await lookup(node.value).timeout(const Duration(seconds: 2));
      return addresses
              .any((address) => _canonicalAddress(address) == peerAddress)
          ? node.key
          : null;
    } on Exception {
      return null;
    }
  }));
  final unique = matches.whereType<int>().toList();
  return unique.length == 1 ? unique.single : null;
}

String _canonicalAddress(InternetAddress address) {
  if (address.type != InternetAddressType.IPv6) return address.address;
  final bytes = address.rawAddress;
  final mapped = bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;
  final nat64 = bytes[0] == 0 &&
      bytes[1] == 0x64 &&
      bytes[2] == 0xff &&
      bytes[3] == 0x9b &&
      bytes.skip(4).take(8).every((byte) => byte == 0);
  return mapped || nat64
      ? InternetAddress.fromRawAddress(Uint8List.sublistView(bytes, 12)).address
      : InternetAddress.fromRawAddress(bytes).address;
}
