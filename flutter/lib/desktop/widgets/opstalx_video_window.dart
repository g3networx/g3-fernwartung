import 'dart:io';

import 'package:flutter/material.dart';
import '../../native/win32.dart' show raiseWindowsViewerPriority;

const opsTalxWindowsEnabled = bool.fromEnvironment('G3_OPSTALX');
const _startPage = 'https://linx.g3nx.net/opstalx/vas';

Future<void> openOpsTalxVideoWindow(
  BuildContext context, {
  bool fromRemoteSession = false,
}) async {
  if (!Platform.isWindows) return;
  final roots = [
    Platform.environment['ProgramFiles(x86)'],
    Platform.environment['ProgramFiles'],
    Platform.environment['LOCALAPPDATA'],
  ].whereType<String>();
  for (final root in roots) {
    for (final relative in const [
      r'Microsoft\Edge\Application\msedge.exe',
      r'Google\Chrome\Application\chrome.exe',
    ]) {
      final browser = File('$root\\$relative');
      if (!await browser.exists()) continue;
      try {
        await Process.start(
          browser.path,
          ['--app=$_startPage'],
          mode: ProcessStartMode.detached,
        );
        // A browser app launch can reuse an existing browser process.
        if (fromRemoteSession && Platform.numberOfProcessors <= 2) {
          final error = raiseWindowsViewerPriority();
          if (error != 0) {
            debugPrint('OpsLinX VAS viewer priority: Windows error $error');
          }
        }
        return;
      } on ProcessException {
        // Try the next installed browser.
      }
    }
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('OpsLinX VAS'),
      content: const Text(
        'Für das separate Video-Fenster wird Microsoft Edge oder Google Chrome benötigt.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Schließen'),
        ),
      ],
    ),
  );
}
