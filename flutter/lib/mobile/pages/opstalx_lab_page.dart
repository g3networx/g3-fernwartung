import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart' show androidVersion;
import '../../g3_addressbook_api.dart';
import '../../g3_addressbook_credentials.dart';

const _host = 'talx.opslinx.de';
const _channel = MethodChannel('mChannel');

class OpsTalxLabPage extends StatefulWidget {
  const OpsTalxLabPage({super.key});

  @override
  State<OpsTalxLabPage> createState() => _OpsTalxLabPageState();
}

class _OpsTalxLabPageState extends State<OpsTalxLabPage> {
  final _code = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _open(Uri uri) async {
    try {
      if (await _channel.invokeMethod<bool>('g3_open_video_help', uri.toString()) ==
          true) return;
    } catch (_) {
      // The embedded view is provided by the Android activity.
    }
    if (mounted) {
      setState(() => _error = 'Die Video-Hilfe konnte nicht geöffnet werden.');
    }
  }

  void _join() {
    final input = _code.text.trim();
    final link = Uri.tryParse(input);
    final value = link != null &&
            link.scheme == 'https' &&
            link.host == _host &&
            link.userInfo.isEmpty &&
            !link.hasPort &&
            link.path == '/vas/'
        ? link.queryParameters['room'] ?? ''
        : input.replaceFirst(RegExp(r'^raumcode\s*:?\s*', caseSensitive: false), '');
    final code = value.toLowerCase().replaceAll(RegExp(r'[\s\u200b\u2060\ufeff‐‑–—-]'), '');
    if (!RegExp(r'^(?:[0-9]{10}|[0-9a-f]{32})$').hasMatch(code)) {
      setState(() => _error = 'Bitte den zehnstelligen Raumcode oder den Einladungslink eingeben.');
      return;
    }
    setState(() => _error = null);
    _open(Uri.https(_host, '/vas/', {'room': code}));
  }

  Future<void> _startForCustomer() async {
    final api = G3AddressBookApi();
    try {
      api.token = await G3AndroidAddressBookCredentials(
        supported: androidVersion >= 23,
      ).read();
      if (api.token == null) {
        if (mounted)
          setState(() => _error =
              'Bitte im g3-Adressbuch anmelden und die Anmeldung speichern.');
        return;
      }
      final list = await api.request('vas/customers');
      final customers =
          (list['customers'] as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      if (customers.isEmpty) {
        setState(() =>
            _error = 'Für dieses Konto ist kein Kunde für VAS freigegeben.');
        return;
      }
      final id = customers.length == 1
          ? customers.single['id'] as int
          : await showDialog<int>(
              context: context,
              builder: (context) => SimpleDialog(
                title: const Text('Kunde für Video-Hilfe'),
                children: [
                  for (final customer in customers)
                    SimpleDialogOption(
                      onPressed: () =>
                          Navigator.pop(context, customer['id'] as int),
                      child: Text(customer['name'] as String),
                    ),
                ],
              ),
            );
      if (id == null || !mounted) return;
      final result = await api.request('vas/start', body: {'customer_id': id});
      final uri = Uri.tryParse(result['url'] as String? ?? '');
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != _host ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort ||
          uri.path != '/vas/launch' ||
          !RegExp(r'^grant=[A-Za-z0-9_.-]+$').hasMatch(uri.fragment)) {
        throw const FormatException('Ungültige VAS-Freigabe');
      }
      if (mounted) await _open(uri);
    } on G3AddressBookExpired {
      if (mounted)
        setState(() => _error = 'Die OpsLinX-Anmeldung ist abgelaufen.');
    } catch (_) {
      if (mounted)
        setState(() => _error =
            'Die OpsLinX-Freigabe für Video-Hilfe ist gerade nicht verfügbar.');
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('OpsLinX VAS',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text('Video-Hilfe mit OpsTalX'),
            const SizedBox(height: 24),
            TextField(
              controller: _code,
              decoration: InputDecoration(
                labelText: 'Raumcode',
                hintText: '123 456 7890',
                errorText: _error,
              ),
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _join(),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _join,
              child: const Text('Video-Hilfe beitreten'),
            ),
            OutlinedButton(
              onPressed: _startForCustomer,
              child: const Text('Als Kunde starten'),
            ),
          ],
        ),
      );
}
