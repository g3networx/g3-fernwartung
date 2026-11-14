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
import 'models/platform_model.dart';

Future<void> showG3AndroidSettings(
  BuildContext context, {
  G3AndroidUpdate? update,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _G3AndroidSettings(update: update),
    );

class _G3AndroidSettings extends StatefulWidget {
  const _G3AndroidSettings({this.update});

  final G3AndroidUpdate? update;

  @override
  State<_G3AndroidSettings> createState() => _G3AndroidSettingsState();
}

class _G3AndroidSettingsState extends State<_G3AndroidSettings> {
  static const _channel = MethodChannel('mChannel');
  var _theme = MyTheme.getThemeModePreference();
  var _record = mainGetLocalBoolOptionSync(kOptionAllowAutoRecordOutgoing);
  bool _checking = false;
  late String? _status = widget.update == null
      ? null
      : '${g3VersionLabel(widget.update!.version)} ist verfügbar.';
  late G3AndroidUpdate? _update = widget.update;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _update = null;
      _status = 'Suche nach Updates …';
    });
    try {
      final update = await g3AvailableAndroidUpdate();
      if (!mounted) return;
      setState(() {
        if (update != null) {
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
