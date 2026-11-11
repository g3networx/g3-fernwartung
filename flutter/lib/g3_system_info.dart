import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';

final class _PrimaryDomainInfo extends Struct {
  @Uint32()
  external int machineRole;
  @Uint32()
  external int flags;
  external Pointer<Utf16> netbiosName;
  external Pointer<Utf16> dnsName;
}

final class _SockaddrIn6 extends Struct {
  @Uint16()
  external int family;
  @Uint16()
  external int port;
  @Uint32()
  external int flowInfo;
  @Array(16)
  external Array<Uint8> address;
  @Uint32()
  external int scopeId;
}

final class _SockaddrIn6Pair extends Struct {
  external Pointer<_SockaddrIn6> source;
  external Pointer<_SockaddrIn6> destination;
}

Uint8List? _sourceAddress(String destinationAddress) {
  final destination = calloc<_SockaddrIn6>();
  final pairs = calloc<Pointer<_SockaddrIn6Pair>>();
  final count = calloc<Uint32>();
  try {
    final library = DynamicLibrary.open('iphlpapi.dll');
    final sort = library.lookupFunction<
        Uint32 Function(
            Pointer<_SockaddrIn6>,
            Uint32,
            Pointer<_SockaddrIn6>,
            Uint32,
            Uint32,
            Pointer<Pointer<_SockaddrIn6Pair>>,
            Pointer<Uint32>),
        int Function(
            Pointer<_SockaddrIn6>,
            int,
            Pointer<_SockaddrIn6>,
            int,
            int,
            Pointer<Pointer<_SockaddrIn6Pair>>,
            Pointer<Uint32>)>('CreateSortedAddressPairs');
    final free = library.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('FreeMibTable');
    // Windows selects a source for a public IPv6 destination without contacting it.
    final target = InternetAddress(destinationAddress).rawAddress;
    destination.ref.family = 23; // AF_INET6 on Windows.
    for (var index = 0; index < target.length; index++) {
      destination.ref.address[index] = target[index];
    }
    try {
      if (sort(nullptr, 0, destination, 1, 0, pairs, count) != 0 ||
          count.value == 0 ||
          pairs.value == nullptr) return null;
      final source = pairs.value.ref.source;
      if (source == nullptr) return null;
      final address = Uint8List(16);
      for (var index = 0; index < address.length; index++) {
        address[index] = source.ref.address[index];
      }
      return address;
    } finally {
      if (pairs.value != nullptr) free(pairs.value.cast());
    }
  } finally {
    calloc.free(destination);
    calloc.free(pairs);
    calloc.free(count);
  }
}

String? _internetIpv6() {
  final address = _sourceAddress('2606:4700:4700::1111');
  if (address == null || (address[0] & 0xe0) != 0x20) return null;
  return InternetAddress.fromRawAddress(address).address;
}

String? _primaryIpv4() {
  final address = _sourceAddress('::ffff:1.1.1.1');
  if (address == null ||
      address.take(10).any((byte) => byte != 0) ||
      address[10] != 0xff ||
      address[11] != 0xff) {
    return null;
  }
  final ipv4 = InternetAddress.fromRawAddress(address.sublist(12));
  return ipv4.isLoopback || ipv4.address == '0.0.0.0' ? null : ipv4.address;
}

String g3RemoteIpv4(Map<dynamic, dynamic> info) {
  final value = info.containsKey('ipv4') ? info['ipv4'] : info['local_ip'];
  final address = value is String ? InternetAddress.tryParse(value) : null;
  return address != null && address.type == InternetAddressType.IPv4
      ? address.address
      : '–';
}

String? _computerDomain() {
  final info = calloc<Pointer<_PrimaryDomainInfo>>();
  try {
    final library = DynamicLibrary.open('netapi32.dll');
    final read = library.lookupFunction<
            Uint32 Function(
                Pointer<Utf16>, Uint32, Pointer<Pointer<_PrimaryDomainInfo>>),
            int Function(
                Pointer<Utf16>, int, Pointer<Pointer<_PrimaryDomainInfo>>)>(
        'DsRoleGetPrimaryDomainInformation');
    final free = library.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('DsRoleFreeMemory');
    try {
      const primaryDomainInfoBasic = 1;
      if (read(nullptr, primaryDomainInfoBasic, info) != 0 ||
          info.value == nullptr) return null;
      final name = info.value.ref.dnsName;
      if (name == nullptr) return null;
      final domain = name.toDartString();
      return domain.isEmpty ? null : domain;
    } finally {
      if (info.value != nullptr) free(info.value.cast());
    }
  } finally {
    calloc.free(info);
  }
}

class G3LocalSystemInfo extends StatefulWidget {
  const G3LocalSystemInfo({super.key});

  @override
  State<G3LocalSystemInfo> createState() => _G3LocalSystemInfoState();
}

class _G3LocalSystemInfoState extends State<G3LocalSystemInfo> {
  late final Future<String?> _ipv4 = _readIpv4();
  late final String? _ipv6 = _internetIpv6();
  late final String? _domain = _computerDomain();

  Future<String?> _readIpv4() async {
    final primary = _primaryIpv4();
    if (primary != null) return primary;
    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      final addresses = interfaces
          .expand((i) => i.addresses)
          .map((address) => address.address)
          .toSet();
      return addresses.length == 1 ? addresses.single : null;
    } on SocketException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = Platform.environment['USERNAME'];
    final accountDomain = Platform.environment['USERDOMAIN'];
    return FutureBuilder<String?>(
      future: _ipv4,
      builder: (context, snapshot) => _SystemInfoCard(
        title: 'Lokales System',
        values: {
          'Hostname': Platform.localHostname,
          'Domäne': _domain ?? '–',
          'Benutzer': user == null
              ? '–'
              : accountDomain == null
                  ? user
                  : '$accountDomain\\$user',
          'IPv4': snapshot.connectionState == ConnectionState.done
              ? snapshot.data ?? '–'
              : '…',
          'IPv6': _ipv6 ?? '–',
        },
      ),
    );
  }
}

class G3RemoteSystemInfo extends StatefulWidget {
  final Map<String, String> values;
  const G3RemoteSystemInfo({super.key, required this.values});

  @override
  State<G3RemoteSystemInfo> createState() => _G3RemoteSystemInfoState();
}

class _G3RemoteSystemInfoState extends State<G3RemoteSystemInfo> {
  bool _visible = true;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    _hide = Timer(const Duration(seconds: 12), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _visible
      ? IgnorePointer(
          child: _SystemInfoCard(
              title: 'Entferntes System', values: widget.values))
      : const SizedBox.shrink();
}

class _SystemInfoCard extends StatelessWidget {
  final String title;
  final Map<String, String> values;

  const _SystemInfoCard({required this.title, required this.values});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              ...values.entries.map((row) {
                final line =
                    '${row.key}: ${row.value.isEmpty ? '–' : row.value}';
                return Tooltip(
                  message: line,
                  child:
                      Text(line, maxLines: 2, overflow: TextOverflow.ellipsis),
                );
              }),
            ],
          ),
        ),
      );
}
