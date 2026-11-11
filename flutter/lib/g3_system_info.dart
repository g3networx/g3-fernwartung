import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';

typedef _JoinNative = Uint32 Function(
    Pointer<Utf16>, Pointer<Pointer<Utf16>>, Pointer<Uint32>);
typedef _JoinDart = int Function(
    Pointer<Utf16>, Pointer<Pointer<Utf16>>, Pointer<Uint32>);

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
  late final Future<List<String>> _addresses = _readAddresses();
  late final String? _domain = _computerDomain();

  Future<List<String>> _readAddresses() async {
    try {
      final interfaces = await NetworkInterface.list();
      return interfaces
          .expand((i) => i.addresses)
          .map((a) => a.address)
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
      future: _addresses,
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
          'IP-Adresse': snapshot.hasData
              ? (snapshot.data!.isEmpty ? '–' : snapshot.data!.join(', '))
              : '…',
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
              for (final row in values.entries)
                Text('${row.key}: ${row.value}',
                    maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      );
}
