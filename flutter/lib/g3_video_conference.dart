import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

bool canStartG3VideoConference(Object? deviceId) =>
    (Platform.isWindows || Platform.isAndroid) &&
    deviceId is String &&
    RegExp(r'^[0-9]{6,16}$').hasMatch(deviceId);

Future<void> openG3VideoConference(
    BuildContext context, String deviceId) async {
  if (!canStartG3VideoConference(deviceId)) return;
  final uri = Uri(
      scheme: 'opstalx',
      host: 'conference',
      queryParameters: {'device': deviceId});
  try {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
  } catch (_) {
    // There may be no installed app that handles the conference link.
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:
            Text('Bitte eine aktuelle Version von OpsTalX installieren.')));
  }
}
