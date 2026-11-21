import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'g3_addressbook_api.dart';

bool canStartG3VideoConference(Object? deviceId) =>
    (Platform.isWindows || Platform.isAndroid) &&
    deviceId is String &&
    RegExp(r'^[0-9]{6,16}$').hasMatch(deviceId);

Future<void> openG3VideoConference(
  BuildContext context,
  String deviceId, {
  G3AddressBookApi? addressBook,
  int? addressBookDevice,
}) async {
  if (!canStartG3VideoConference(deviceId)) return;
  String? conferenceGrant;
  if (addressBook != null && addressBookDevice != null) {
    try {
      final result = await addressBook
          .request('conference/start', body: {'device_id': addressBookDevice});
      final grant = result['grant'];
      if (result['device'] != deviceId ||
          grant is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{1,1000}\.[A-Za-z0-9_-]{86}$')
              .hasMatch(grant)) {
        throw const FormatException('Invalid conference grant.');
      }
      conferenceGrant = 'grant=$grant';
    } on G3AddressBookExpired {
      if (context.mounted) {
        _showConferenceMessage(
            context, 'Bitte wieder im g3-Adressbuch anmelden.');
      }
      return;
    } on G3AddressBookRequestError catch (error) {
      if (context.mounted) {
        _showConferenceMessage(
            context,
            error.status == 403
                ? 'Für dieses Gerät ist der Konferenzstart nicht freigegeben.'
                : 'Die Konferenz konnte nicht gestartet werden.');
      }
      return;
    } catch (_) {
      if (context.mounted) {
        _showConferenceMessage(
            context, 'Die Konferenz konnte nicht gestartet werden.');
      }
      return;
    }
  }
  if (!context.mounted) return;
  final uri = Uri(
      scheme: 'opstalx',
      host: 'conference',
      queryParameters: {'device': deviceId},
      fragment: conferenceGrant);
  try {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
  } catch (_) {
    // There may be no installed app that handles the conference link.
  }
  if (context.mounted) {
    _showConferenceMessage(
        context, 'Bitte eine aktuelle Version von OpsTalX installieren.');
  }
}

void _showConferenceMessage(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
