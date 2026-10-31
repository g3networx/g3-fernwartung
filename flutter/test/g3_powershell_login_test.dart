import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/g3_powershell_login.dart';
import 'package:flutter_hbb/g3_powershell_credentials.dart';

class MemoryCredentials extends G3PowerShellCredentials {
  var writes = 0;
  @override
  bool get supported => true;
  @override
  Future<Map<String, String>?> read(String deviceId) async =>
    {'username': r'EXAMPLE\saved-support', 'password': 'saved fixture password'};
  @override
  Future<void> write(String deviceId, String username, String password) async {writes++;}
}

void main() {
  testWidgets('Administrator login requires account and password and describes SYSTEM', (tester) async {
    G3PowerShellLogin? login;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
      onPressed: () async { login = await showG3PowerShellLogin(context); }, child: const Text('Open')))));
    await tester.tap(find.text('Open')); await tester.pumpAndSettle();
    expect(find.textContaining('Nach erfolgreicher Prüfung läuft die Shell als SYSTEM'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Verbinden')); await tester.pumpAndSettle();
    expect(find.text('Benutzer angeben'), findsOneWidget);
    expect(find.text('Kennwort angeben'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).at(0), r'EXAMPLE\support');
    await tester.enterText(find.byType(TextFormField).at(1), ' fixture password ');
    expect(tester.widget<TextField>(find.byType(TextField).last).obscureText, isTrue);
    await tester.tap(find.widgetWithText(FilledButton, 'Verbinden')); await tester.pumpAndSettle();
    expect(login?.username, r'EXAMPLE\support');
    expect(login?.password, ' fixture password ');
    login?.clear(); expect(login?.password, '');
  });

  testWidgets('Cancel returns no login or connection request', (tester) async {
    final credentials = MemoryCredentials();
    var completed = false;
    G3PowerShellLogin? login;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
      onPressed: () async { login = await showG3PowerShellLogin(context, deviceId: 'fixture-target', credentials: credentials); completed = true; }, child: const Text('Open')))));
    await tester.tap(find.text('Open')); await tester.pumpAndSettle();
    expect(find.text(r'EXAMPLE\saved-support'), findsOneWidget);
    expect(completed, isFalse);
    expect(credentials.writes, 0);
    await tester.tap(find.text('Abbrechen')); await tester.pumpAndSettle();
    expect(completed, isTrue); expect(login, isNull);
    expect(credentials.writes, 0);
  });

  test('Only a submitted verified login is saved and transient secrets are cleared', () async {
    final credentials = MemoryCredentials();
    final pending = {'deviceId': 'fixture-target', 'username': r'EXAMPLE\support',
      'password': 'fixture password', 'save': 'Y'};
    expect(await saveVerifiedG3PowerShellLogin(pending, credentials: credentials), isFalse);
    expect(credentials.writes, 0);expect(pending, isEmpty);
    final verified = {'deviceId': 'fixture-target', 'username': r'EXAMPLE\support',
      'password': 'fixture password', 'save': 'Y', 'submitted': 'Y'};
    expect(await saveVerifiedG3PowerShellLogin(verified, credentials: credentials), isTrue);
    expect(credentials.writes, 1);expect(verified, isEmpty);
  });

  test('Windows vault roundtrip is device-scoped and removable', () async {
    final id = 'fixture-${DateTime.now().microsecondsSinceEpoch}';
    final store = G3PowerShellCredentials();
    try {
      await store.write(id, r'EXAMPLE\fixture', 'not a real credential ü ');
      final saved = await G3PowerShellCredentials().read(id);
      expect(saved?['username'], r'EXAMPLE\fixture');
      expect(saved?['password'], 'not a real credential ü ');
      saved?.clear();
      expect(await store.read('$id-other'), isNull);
    } finally {await store.delete(id);}
    expect(await store.read(id), isNull);
  }, skip: !Platform.isWindows);
}
