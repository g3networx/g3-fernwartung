import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'common.dart';
import 'common/widgets/g3_relay_setting.dart';
import 'consts.dart';
import 'g3_android_update_transport.dart';
import 'g3_update_check.dart';
import 'g3_update_metadata.dart';
import 'models/platform_model.dart';

Future<void> showG3AndroidSettings(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _G3AndroidSettings(),
    );

class _G3AndroidSettings extends StatefulWidget {
  const _G3AndroidSettings();

  @override
  State<_G3AndroidSettings> createState() => _G3AndroidSettingsState();
}

class _G3AndroidSettingsState extends State<_G3AndroidSettings> {
  static const _channel = MethodChannel('mChannel');
  var _theme = MyTheme.getThemeModePreference();
  var _record = mainGetLocalBoolOptionSync(kOptionAllowAutoRecordOutgoing);
  bool _checking = false;
  String? _status;
  ({String version, String digest, int size})? _update;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _update = null;
      _status = 'Suche nach Updates …';
    });
    try {
      final update = await g3AndroidUpdateRequest('/client/android/update.json',
          (response) async {
        final bytes = <int>[];
        await for (final chunk
            in response.stream.timeout(const Duration(seconds: 8))) {
          if (bytes.length + chunk.length > 16384) throw const FormatException();
          bytes.addAll(chunk);
        }
        final data = jsonDecode(utf8.decode(bytes));
        if (data is! Map<String, dynamic>) throw const FormatException();
        final version = data['version'];
        final digest = data['sha256'];
        final size = data['size'];
        if (version is! String ||
            !g3VersionIsValid(version) ||
            digest is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
            size is! int ||
            size <= 0 ||
            size > g3MaximumUpdateArtifactSize) {
          throw const FormatException();
        }
        return (version: version, digest: digest, size: size);
      });
      if (!mounted) return;
      setState(() {
        if (g3VersionNewer(update.version, g3ClientVersion)) {
          _update = update;
          _status = '${g3VersionLabel(update.version)} ist verfügbar.';
        } else {
          _status = 'Dieser Client ist aktuell.';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _status = 'Updateprüfung derzeit nicht möglich.');
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _install() async {
    final update = _update;
    if (update == null) return;
    setState(() {
      _checking = true;
      _status = 'Update wird heruntergeladen und geprüft …';
    });
    File? pending;
    try {
      final cache = await getTemporaryDirectory();
      final dir = await Directory('${cache.path}/opslinx-updates').create();
      final download = File('${dir.path}/update.pending');
      pending = download;
      await g3AndroidUpdateRequest('/client/platform/android_arm64',
          (response) async {
        if (response.contentLength != null &&
            response.contentLength != update.size) {
          throw const FormatException();
        }
        var received = 0;
        final sink = download.openWrite();
        try {
          await sink.addStream(
              response.stream.timeout(const Duration(seconds: 30)).map((chunk) {
            received += chunk.length;
            if (received > update.size) throw const FormatException();
            return chunk;
          }));
        } finally {
          await sink.close();
        }
        if (received != update.size ||
            (await sha256.bind(download.openRead()).first).toString() !=
                update.digest) {
          throw const FormatException();
        }
      });
      await download.rename('${dir.path}/update.apk');
      if (!mounted) return;
      await _channel.invokeMethod<void>('g3_install_android_update');
      if (mounted) {
        setState(() => _status = 'Installation in Android bestätigen.');
      }
    } catch (_) {
      if (mounted) {
        setState(() =>
            _status = 'Update konnte nicht geprüft oder geöffnet werden.');
      }
    } finally {
      try {
        if (pending != null && await pending.exists()) await pending.delete();
      } finally {
        if (mounted) setState(() => _checking = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Einstellungen'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (mode, label) in [
              (ThemeMode.light, 'Hell'),
              (ThemeMode.dark, 'Dunkel')
            ])
              RadioListTile<ThemeMode>(
                title: Text(label),
                value: mode,
                groupValue: _theme,
                onChanged: isOptionFixed(kCommConfKeyTheme)
                    ? null
                    : (value) {
                        if (value == null) return;
                        MyTheme.changeDarkMode(value);
                        setState(() => _theme = value);
                      },
              ),
            SwitchListTile(
              title: const Text('Ausgehende Sitzungen automatisch aufzeichnen'),
              value: _record,
              onChanged: isOptionFixed(kOptionAllowAutoRecordOutgoing)
                  ? null
                  : (value) async {
                      await bind.mainSetLocalOption(
                        key: kOptionAllowAutoRecordOutgoing,
                        value:
                            bool2option(kOptionAllowAutoRecordOutgoing, value),
                      );
                      if (mounted) {
                        setState(() => _record = mainGetLocalBoolOptionSync(
                            kOptionAllowAutoRecordOutgoing));
                      }
                    },
            ),
            const Divider(),
            const G3RelaySetting(),
            const Text(g3DisplayVersion),
            if (_status != null) Text(_status!),
            TextButton(
              onPressed:
                  _checking ? null : (_update == null ? _check : _install),
              child: Text(_update == null
                  ? 'Auf Updates prüfen'
                  : 'Update installieren'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Schließen'),
          ),
        ],
      );
}
