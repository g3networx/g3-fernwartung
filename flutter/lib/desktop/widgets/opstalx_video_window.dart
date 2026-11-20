import 'dart:io';

import 'package:flutter/material.dart';
import '../../g3_addressbook_api.dart';
import '../../native/win32.dart' show raiseWindowsViewerPriority;
import '../../utils/multi_window_manager.dart';

const opsTalxWindowsEnabled = bool.fromEnvironment('G3_OPSTALX');
const kOpsTalxRoomRequest = 'opstalx_room_request';

Future<Map<String, dynamic>> requestOpsTalxRoom(
    G3AddressBookApi api, int? customerId) async {
  try {
    if (api.token == null) throw G3AddressBookExpired();
    return customerId == null
        ? await api.request('vas/customers')
        : await api.request('vas/start', body: {'customer_id': customerId});
  } on G3AddressBookExpired {
    return {'error': 'Bitte im g3-Adressbuch anmelden.'};
  } on G3AddressBookRequestError catch (error) {
    if (error.status == 403) {
      return {'error': 'Für dieses Konto ist keine Video-Hilfe freigegeben.'};
    }
    rethrow;
  }
}

Future<void> openOpsTalxVideoWindow(
  BuildContext context, {
  G3AddressBookApi? addressBookApi,
  bool fromRemoteSession = false,
}) async {
  if (!Platform.isWindows) return;
  Future<Map<String, dynamic>> request(int? customer) async {
    final reply = addressBookApi == null
        ? (await rustDeskWinManager.call(
            WindowType.Main, kOpsTalxRoomRequest, customer)).result
        : await requestOpsTalxRoom(addressBookApi, customer);
    final response = Map<String, dynamic>.from(reply as Map);
    final message = response['error'];
    if (message is String) throw FormatException(message);
    return response;
  }

  Uri uri;
  try {
    final customers = (await request(null))['customers'] as List;
    if (customers.isEmpty) {
      throw const FormatException('Für dieses Konto ist keine Video-Hilfe freigegeben.');
    }
    if (!context.mounted) return;
    final customer = customers.length == 1
        ? customers.single['id'] as int
        : await showDialog<int>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('Kunde für Video-Hilfe'),
              children: [
                for (final entry in customers)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, entry['id'] as int),
                    child: Text(entry['name'] as String),
                  ),
              ],
            ),
          );
    if (customer == null || !context.mounted) return;
    uri = Uri.parse((await request(customer))['url'] as String);
    if (uri.scheme != 'https' ||
        uri.host != 'talx.opslinx.de' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.path != '/vas/launch' ||
        uri.hasQuery ||
        !RegExp(r'^grant=[A-Za-z0-9_-]{1,1000}\.[A-Za-z0-9_-]{86}$')
            .hasMatch(uri.fragment)) {
      throw const FormatException('Ungültige Freigabe für die Video-Hilfe.');
    }
  } on FormatException catch (error) {
    if (context.mounted) {
      await _showVideoHelpError(context, error.message);
    }
    return;
  } catch (_) {
    if (context.mounted) {
      await _showVideoHelpError(context, 'Video-Hilfe konnte nicht gestartet werden.');
    }
    return;
  }

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
          ['--app=$uri'],
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
  await _showVideoHelpError(context,
      'Für das separate Video-Fenster wird Microsoft Edge oder Google Chrome benötigt.');
}

Future<void> _showVideoHelpError(BuildContext context, String message) =>
    showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('OpsLinX VAS'),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Schließen'),
        ),
      ],
    ),
  );
