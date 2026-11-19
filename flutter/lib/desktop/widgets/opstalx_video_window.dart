import 'dart:io';

import 'package:flutter/material.dart';

const opsTalxWindowsLab = bool.fromEnvironment('G3_OPSTALX_LAB');
const _startPage = 'https://talx.opslinx.de/ar/start';

Future<void> openOpsTalxVideoWindow(BuildContext context) async {
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
      title: const Text('OpsTalX'),
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
