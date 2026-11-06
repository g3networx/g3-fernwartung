import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/g3_local_addressbook_crypto.dart';
import 'package:flutter_hbb/g3_local_addressbook_store.dart';
import 'package:flutter_hbb/g3_local_addressbook_password_dialog.dart';

void main() {
  test(
      'DPAPI protects stored passwords, preserves edits and binds the device ID',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('g3-password-store-test-');
    try {
      final store =
          G3LocalAddressBookStore(File('${directory.path}/book.json'));
      const secret = ' Device-Password-Ü9! ';
      await store.put(G3LocalEntry(id: '123456789', name: 'Büro'),
          password: secret);
      final disk = await store.file.readAsString();
      expect(disk.contains(secret), isFalse);
      expect(jsonDecode(disk)['version'], 2);
      var entry = (await store.read()).single;
      expect(await store.passwordFor(entry), secret);
      expect(
          () => G3LocalPasswordCipher()
              .unprotect(entry.passwordProtected, '987654321'),
          throwsStateError);
      await store.put(G3LocalEntry(id: '987654321', name: 'Umbenannt'),
          previousId: entry.id);
      entry = (await store.read()).single;
      expect(await store.passwordFor(entry), secret);
      await store.put(G3LocalEntry(id: entry.id, name: 'Weiterhin geschützt'),
          previousId: entry.id);
      expect(await store.passwordFor((await store.read()).single), secret);
      await store.put(G3LocalEntry(id: entry.id, name: 'Ohne Kennwort'),
          previousId: entry.id, removePassword: true);
      expect((await store.read()).single.passwordProtected, isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test(
      'password-protected export imports and re-protects secrets; wrong keys and tampering fail closed',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('g3-encrypted-export-test-');
    try {
      final source =
          G3LocalAddressBookStore(File('${directory.path}/source.json'));
      final target =
          G3LocalAddressBookStore(File('${directory.path}/target.json'));
      const devicePassword = 'Device/Test-Ü9! ';
      const exportPassword = 'Portable Export Password! 73';
      await source.put(
          G3LocalEntry(id: '123456789', name: 'Vertraulicher Gerätename'),
          password: devicePassword);
      final encrypted = await source.encryptedExport(exportPassword);
      expect(encrypted.contains(devicePassword), isFalse);
      expect(encrypted.contains('Vertraulicher Gerätename'), isFalse);
      expect(encrypted.contains(exportPassword), isFalse);
      final opened =
          await target.openEncryptedExport(encrypted, exportPassword);
      expect(await target.importEntries(opened), 1);
      expect(await target.passwordFor((await target.read()).single),
          devicePassword);
      expect((await source.read()).single.passwordProtected,
          isNot((await target.read()).single.passwordProtected));
      expect(
          (await target.file.readAsString()).contains(devicePassword), isFalse);
      final before = await target.file.readAsBytes();
      await expectLater(
          target.openEncryptedExport(encrypted, 'Wrong export password!'),
          throwsFormatException);
      final modified = jsonDecode(encrypted) as Map<String, dynamic>;
      final tag = base64Decode(modified['tag']);
      tag[0] ^= 1;
      modified['tag'] = base64Encode(tag);
      await expectLater(
          target.openEncryptedExport(jsonEncode(modified), exportPassword),
          throwsFormatException);
      expect(await target.file.readAsBytes(), before);
      modified['iterations'] = 1000000000;
      await expectLater(
          target.openEncryptedExport(jsonEncode(modified), exportPassword),
          throwsFormatException);
    } finally {
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('legacy v1 metadata migrates without plaintext passwords', () async {
    final directory =
        await Directory.systemTemp.createTemp('g3-legacy-book-test-');
    try {
      final store =
          G3LocalAddressBookStore(File('${directory.path}/book.json'));
      await store.file.writeAsString(jsonEncode({
        'format': 'g3-local-addressbook',
        'version': 1,
        'entries': [
          {'id': '123456789', 'name': 'Alt', 'group': '', 'notes': ''}
        ]
      }));
      final old = (await store.read()).single;
      await store.put(G3LocalEntry(id: old.id, name: old.name),
          previousId: old.id, password: 'New connection password!');
      expect(jsonDecode(await store.file.readAsString())['version'], 2);
      expect(await store.passwordFor((await store.read()).single),
          'New connection password!');
    } finally {
      await directory.delete(recursive: true);
    }
  });

  testWidgets(
      'export dialog requires matching passwords and returns exact whitespace',
      (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      child: const Text('Export'),
                      onPressed: () async {
                        result = await showG3LocalExportPassword(context,
                            exporting: true);
                      },
                    )))));
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextFormField).at(0), ' Export password! ');
    await tester.enterText(
        find.byType(TextFormField).at(1), 'Different value!');
    await tester.tap(find.text('Weiter'));
    await tester.pumpAndSettle();
    expect(find.text('Die Kennwörter stimmen nicht überein.'), findsOneWidget);
    expect(result, isNull);
    await tester.enterText(
        find.byType(TextFormField).at(1), ' Export password! ');
    await tester.tap(find.text('Weiter'));
    await tester.pumpAndSettle();
    expect(result, ' Export password! ');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
