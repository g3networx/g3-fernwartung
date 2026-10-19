import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_hbb/g3_enrollment.dart';
import 'package:flutter_hbb/models/platform_model.dart';

const g3ClientVersion = '1.5.0-g3.14';
Future<void> showG3Update(BuildContext context) async {
  await showDialog<void>(
      context: context, builder: (_) => const _G3UpdateDialog());
}

class _G3UpdateDialog extends StatefulWidget {
  const _G3UpdateDialog();
  @override
  State<_G3UpdateDialog> createState() => _G3UpdateState();
}

class _G3UpdateState extends State<_G3UpdateDialog> {
  String message = 'Versionsstand wird geprüft …';
  bool busy = true;
  Map<String, dynamic>? release;
  @override
  void initState() {
    super.initState();
    check();
  }

  List<int> parts(String v) =>
      RegExp(r'\d+').allMatches(v).map((m) => int.parse(m.group(0)!)).toList();
  bool newer(String candidate) {
    final a = parts(candidate), b = parts(g3ClientVersion);
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  Future<void> check() async {
    try {
      final r = await http
          .get(Uri.https('rust.g3nx.net', '/client/update.json'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw Exception();
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      if (!RegExp(r'^\d+\.\d+\.\d+-g3\.\d+$')
          .hasMatch(data['version'] as String)) throw Exception();
      if (mounted)
        setState(() {
          release = newer(data['version']) ? data : null;
          message = release == null
              ? 'Dieser Client ist aktuell ($g3ClientVersion).'
              : 'Version ${data['version']} ist verfügbar. Das Update beendet diesen Client und kann laufende Fernwartungen unterbrechen. Auf dem Zielgerät wird dessen eigener Client aktualisiert; diese Funktion aktualisiert diesen Rechner.';
          busy = false;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          message =
              'Updateprüfung derzeit nicht möglich. Bitte später erneut versuchen.';
          busy = false;
        });
    }
  }

  Future<void> update() async {
    setState(() {
      busy = true;
      message = 'Update wird heruntergeladen und geprüft …';
    });
    try {
      final variant = bind.mainGetAppNameSync()=='g3Host'?'host':'windows';
      final kind = g3IsAdhoc() ? 'adhoc' : (release!.containsKey('${variant}_msi')?'${variant}_msi':variant);
      final item = release![kind] as Map<String, dynamic>;
      final expected = item['sha256'] as String;
      final size = item['size'] as int;
      final name = item['file'] as String;
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(expected) ||
          size < 100000 ||
          size > 150000000 ||
          !RegExp(r'^[A-Za-z0-9._-]+\.(exe|msi)$').hasMatch(name)) throw Exception();
      final r = await http
          .get(Uri.https('rust.g3nx.net', '/client/download/$kind'))
          .timeout(const Duration(minutes: 3));
      if (r.statusCode != 200 ||
          r.bodyBytes.length != size ||
          sha256.convert(r.bodyBytes).toString() != expected) throw Exception();
      final folder = await Directory.systemTemp.createTemp('g3-update-');
      final file = File('${folder.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(r.bodyBytes, flush: true);
      if (name.endsWith('.msi')) {
        final windows = Platform.environment['SystemRoot'] ?? r'C:\Windows';
        await Process.start('$windows\\System32\\msiexec.exe', ['/i', file.path, 'REBOOT=ReallySuppress', '/norestart'], mode: ProcessStartMode.detached);
      } else {
        await Process.start(file.path, ['--g3-wait-pid', pid.toString()], mode: ProcessStartMode.detached);
      }
      exit(0);
    } catch (_) {
      if (mounted)
        setState(() {
          busy = false;
          message =
              'Update konnte nicht sicher geprüft oder gestartet werden. Der bisherige Client bleibt aktiv.';
        });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('g3 Client aktualisieren'),
          content: SizedBox(width: 440, child: Text(message)),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Schließen')),
            if (release != null)
              FilledButton(
                  onPressed: busy ? null : update,
                  child: const Text('Update herunterladen und starten'))
          ]);
}
