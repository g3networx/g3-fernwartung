import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

const _host = 'talx.opslinx.de';

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
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // An Android browser is required for camera and microphone access.
    }
    if (mounted) {
      setState(() => _error = 'Kein Browser zum Öffnen von OpsTalX verfügbar.');
    }
  }

  void _join() {
    final code = _code.text.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(code)) {
      setState(() => _error = 'Bitte den vollständigen Raumcode eingeben.');
      return;
    }
    setState(() => _error = null);
    _open(Uri.https(_host, '/ar/', {'room': code}));
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('OpsLinX AR', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text('Video-Hilfe mit OpsTalX'),
            const SizedBox(height: 24),
            TextField(
              controller: _code,
              decoration: InputDecoration(
                labelText: 'Raumcode',
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
              onPressed: () => _open(Uri.https(_host, '/ar/start')),
              child: const Text('Als Kunde starten'),
            ),
          ],
        ),
      );
}
