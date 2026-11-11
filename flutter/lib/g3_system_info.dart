import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';

typedef _JoinNative = Uint32 Function(
    Pointer<Utf16>, Pointer<Pointer<Utf16>>, Pointer<Uint32>);
typedef _JoinDart = int Function(
    Pointer<Utf16>, Pointer<Pointer<Utf16>>, Pointer<Uint32>);

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

String? _internetIpv6() {
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
    final target = InternetAddress('2606:4700:4700::1111').rawAddress;
    destination.ref.family = 23; // AF_INET6 on Windows.
    for (var index = 0; index < target.length; index++) {
      destination.ref.address[index] = target[index];
    }
    try {
      if (sort(nullptr, 0, destination, 1, 0, pairs, count) != 0 ||
          count.value == 0 ||
          pairs.value == nullptr) return null;
      final source = pairs.value.ref.source;
      if (source == nullptr || (source.ref.address[0] & 0xe0) != 0x20) {
        return null;
      }
      final address = Uint8List(16);
      for (var index = 0; index < address.length; index++) {
        address[index] = source.ref.address[index];
      }
      return InternetAddress.fromRawAddress(address).address;
    } finally {
      if (pairs.value != nullptr) free(pairs.value.cast());
    }
  } finally {
    calloc.free(destination);
    calloc.free(pairs);
    calloc.free(count);
  }
}

String? _computerDomain() {
  final name = calloc<Pointer<Utf16>>();
  final status = calloc<Uint32>();
  try {
    final library = DynamicLibrary.open('netapi32.dll');
    final join =
        library.lookupFunction<_JoinNative, _JoinDart>('NetGetJoinInformation');
    final free = library.lookupFunction<Uint32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('NetApiBufferFree');
    try {
      if (join(nullptr, name, status) != 0 ||
          status.value != 3 ||
          name.value == nullptr) return null;
      return name.value.toDartString();
    } finally {
      if (name.value != nullptr) free(name.value.cast());
    }
  } finally {
    calloc.free(name);
    calloc.free(status);
  }
}

class G3LocalSystemInfo extends StatefulWidget {
  const G3LocalSystemInfo({super.key});

  @override
  State<G3LocalSystemInfo> createState() => _G3LocalSystemInfoState();
}

class _G3LocalSystemInfoState extends State<G3LocalSystemInfo> {
  late final Future<List<String>> _ipv4 = _readIpv4();
  late final String? _ipv6 = _internetIpv6();
  late final String? _domain = _computerDomain();

  Future<List<String>> _readIpv4() async {
    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      return interfaces
          .expand((i) => i.addresses)
          .map((address) => address.address)
          .toSet()
          .toList();
    } on SocketException {
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = Platform.environment['USERNAME'];
    final accountDomain = Platform.environment['USERDOMAIN'];
    return FutureBuilder<List<String>>(
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
          'IPv4': snapshot.hasData ? snapshot.data!.join(', ') : '…',
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
