import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/g3_local_addressbook.dart';
import 'package:flutter_hbb/g3_local_addressbook_store.dart';
import 'package:flutter_hbb/g3_local_addressbook_crypto.dart';

class WidgetBookStore extends G3LocalAddressBookStore {
  List<G3LocalEntry> entries = [
    G3LocalEntry(
        id: '123456789',
        name: 'Büro',
        group: 'Steinmeier',
        passwordProtected: G3LocalPasswordCipher()
            .protect('Local-Test-Password! ', '123456789')),
    G3LocalEntry(id: '987654321', name: 'Labor'),
  ];
  WidgetBookStore() : super(File('unused-widget-fixture'));
  @override
  Future<List<G3LocalEntry>> read() async => List.of(entries);
  @override
  Future<List<String>> readBooks() async =>
      G3LocalAddressBookStore.bookPaths(entries.map((e) => e.book));
  @override
  Future<void> put(G3LocalEntry entry,
      {String? previousId,
      String? password,
      bool removePassword = false}) async {
    final previous =
        entries.firstWhere((e) => e.id == previousId, orElse: () => entry);
    final protected = removePassword
        ? ''
        : password == null
            ? previous.passwordProtected
            : G3LocalPasswordCipher().protect(password, entry.id);
    entries = [
      entry.withPassword(protected),
      ...entries.where((e) => e.id != previousId)
    ];
  }
}

void main() {
  late Directory directory;
  late G3LocalAddressBookStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('g3-local-book-test-');
    store = G3LocalAddressBookStore(File('${directory.path}/book.json'));
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('local edits survive reload and export/import to another PC store',
      () async {
    await store.put(G3LocalEntry(
        id: '123456789',
        name: 'Büro',
        group: 'Steinmeier',
        notes: 'Testgerät'));
    await store.put(
        G3LocalEntry(
            id: '123456789',
            name: 'Büro neu',
            group: 'Steinmeier',
            notes: 'Aktuell'),
        previousId: '123456789');
    final reloaded = G3LocalAddressBookStore(store.file);
    final exported = G3LocalAddressBookStore.encode(await reloaded.read());
    final other =
        G3LocalAddressBookStore(File('${directory.path}/other-pc/book.json'));
    expect(
        await other.importEntries(G3LocalAddressBookStore.decode(exported)), 1);
    expect((await other.read()).single.toJson(), {
      'id': '123456789',
      'name': 'Büro neu',
      'group': 'Steinmeier',
      'notes': 'Aktuell'
    });
    await other.remove('123456789');
    expect(await other.read(), isEmpty);
    expect((await store.read()).single.name, 'Büro neu');
  });

  test('merge preserves existing entries and invalid import never changes them',
      () async {
    await store.put(G3LocalEntry(id: '123456789', name: 'Original'));
    final imported = [
      G3LocalEntry(id: '123456789', name: 'Fremd'),
      G3LocalEntry(id: '987654321', name: 'Neu')
    ];
    expect(await store.importEntries(imported), 1);
    expect((await store.read()).first.name, 'Original');
    final before = await store.file.readAsBytes();
    expect(
        () => G3LocalAddressBookStore.decode(
            '{"format":"g3-local-addressbook","version":99,"entries":[]}'),
        throwsFormatException);
    expect(
        () => G3LocalAddressBookStore.decode(
            '{"format":"g3-local-addressbook","version":1,"entries":[{"id":"123456789","name":"x","password":"secret"}]}'),
        throwsFormatException);
    await expectLater(
        store.put(G3LocalEntry(id: '123456789', name: 'Überschreiben')),
        throwsFormatException);
    expect(await store.file.readAsBytes(), before);
    await store.file.writeAsString('{broken');
    await expectLater(store.importEntries(imported), throwsFormatException);
    expect(await store.file.readAsString(), '{broken');
  });

  test('nested and empty local books survive encrypted transfer and edits',
      () async {
    await store.addBook('Steinmeier/Buero');
    await store.addBook('Steinmeier/Leer');
    await store.put(
        G3LocalEntry(id: '123456789', name: 'PC', book: 'Steinmeier/Buero'),
        password: 'Stored password!');
    await store.put(
        G3LocalEntry(id: '123456789', name: 'PC', book: 'Steinmeier'),
        previousId: '123456789');
    expect(await store.passwordFor((await store.read()).single),
        'Stored password!');
    final target =
        G3LocalAddressBookStore(File('${directory.path}/target.json'));
    final opened = await target.openEncryptedBook(
        await store.encryptedExport('Export password 123!'),
        'Export password 123!');
    await target.importEntries(opened.entries, books: opened.books);
    expect(await target.readBooks(),
        ['Steinmeier', 'Steinmeier/Buero', 'Steinmeier/Leer']);
    expect((await target.read()).single.book, 'Steinmeier');
    expect(await target.passwordFor((await target.read()).single),
        'Stored password!');
    await expectLater(target.removeBook('Steinmeier'), throwsFormatException);
    await target.removeBook('Steinmeier/Leer');
    expect(await target.readBooks(), ['Steinmeier', 'Steinmeier/Buero']);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('local book view filters entries and creates empty subbooks',
      (tester) async {
    await tester.runAsync(() async {
      await store.addBook('Kunde/Buero');
      await store.put(G3LocalEntry(
          id: '123456789', name: 'Buerorechner', book: 'Kunde/Buero'));
      await store.put(G3LocalEntry(id: '987654321', name: 'Sonstiger PC'));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: G3LocalAddressBook(
                  store: store, onConnect: (_, __, ___) async {}))));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alle lokalen Einträge'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kunde/Buero').last);
    await tester.pumpAndSettle();
    expect(find.text('Buerorechner'), findsOneWidget);
    expect(find.text('Sonstiger PC'), findsNothing);
    await tester.runAsync(() => tester.tap(find.text('Unteradressbuch')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Leer');
    await tester.runAsync(() async {
      await tester.tap(find.text('Anlegen'));
      await tester.pump(const Duration(milliseconds: 350));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => store.readBooks()),
        contains('Kunde/Buero/Leer'));
    expect(find.text('Buerorechner'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'local book works without server login, searches and connects by ID',
      (tester) async {
    final widgetStore = WidgetBookStore();
    final connected = <String>[];
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: G3LocalAddressBook(
                  store: widgetStore,
                  onConnect: (id, files, password) async {
                    expect(password, 'Local-Test-Password! ');
                    connected.add('$id:$files');
                  }))));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('Büro'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Steinmeier');
    await tester.pumpAndSettle();
    expect(find.text('Labor'), findsNothing);
    await tester.tap(find.byTooltip('Desktop verbinden'));
    await tester.pumpAndSettle();
    expect(connected, ['123456789:false']);
    await tester.tap(find.byTooltip('Weitere Aktionen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dateiexplorer'));
    await tester.pumpAndSettle();
    expect(connected.last, '123456789:true');
    await tester.tap(find.byTooltip('Weitere Aktionen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bearbeiten'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Büro geändert');
    await tester.runAsync(() async {
      await tester.tap(find.text('Speichern'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('Büro geändert'), findsOneWidget);
    expect(await widgetStore.passwordFor(widgetStore.entries.first),
        'Local-Test-Password! ');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
