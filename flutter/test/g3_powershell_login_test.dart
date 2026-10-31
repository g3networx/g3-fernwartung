import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/g3_powershell_login.dart';

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
    var completed = false;
    G3PowerShellLogin? login;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
      onPressed: () async { login = await showG3PowerShellLogin(context); completed = true; }, child: const Text('Open')))));
    await tester.tap(find.text('Open')); await tester.pumpAndSettle();
    await tester.tap(find.text('Abbrechen')); await tester.pumpAndSettle();
    expect(completed, isTrue); expect(login, isNull);
  });
}
