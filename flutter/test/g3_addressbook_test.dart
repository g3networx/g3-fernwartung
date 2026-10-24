import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_hbb/g3_addressbook.dart';
import 'package:flutter_hbb/g3_addressbook_api.dart';
import 'package:flutter_hbb/g3_addressbook_credentials.dart';

class FixtureCredentials extends G3AddressBookCredentials {
  bool deleted = false;
  @override
  bool get supported => true;
  @override
  Future<String?> read() async => 'a' * 43;
  @override
  Future<void> delete() async {
    deleted = true;
  }
}

void main() {
  test('Windows remembers a revocable token across store instances', () async {
    final target =
        'g3 OpsLinX/AddressBook/fixture-${DateTime.now().microsecondsSinceEpoch}';
    final store = G3AddressBookCredentials(target: target);
    try {
      await store.write('b' * 43);
      expect(await G3AddressBookCredentials(target: target).read(), 'b' * 43);
    } finally {
      await store.delete();
    }
    expect(await store.read(), isNull);
  }, skip: !Platform.isWindows);
  final tree = {
    'username': 'fixture@g3.test',
    'books': [
      {'id': 1, 'parent_id': null, 'name': 'Own', 'path': 'Own'},
      {'id': 3, 'parent_id': 1, 'name': 'Servers', 'path': 'Own › Servers'},
    ],
    'devices': [
      {
        'id': 7,
        'customer_id': 3,
        'name': 'TEST-SERVER',
        'rustdesk_id': '123456789',
        'presence': 'online'
      },
    ],
  };

  test('API decodes the server tree as UTF-8', () async {
    final api = G3AddressBookApi(
        client: MockClient((_) async => http.Response(jsonEncode(tree), 200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    expect((await api.request('tree'))['username'], 'fixture@g3.test');
    api.close();
  });

  testWidgets('Restores login, filters nested tree, shows details and connects',
      (tester) async {
    tester.view.reset();
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? opened;
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer ${'a' * 43}');
      if (request.url.path.endsWith('/connect')) {
        expect(jsonDecode(request.body)['device_id'], 7);
        return http.Response(
            jsonEncode({'uri': 'g3fernwartung://123456789'}), 200);
      }
      return http.Response(jsonEncode(tree), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: G3AddressBook(
                api: G3AddressBookApi(client: client),
                credentials: FixtureCredentials(),
                onConnect: (uri) async {
                  opened = uri;
                }))));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('fixture@g3.test'), findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join(' | '));
    await tester.enterText(find.byType(TextField), '123456789');
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('Own'), findsOneWidget);
    expect(find.text('Servers'), findsOneWidget);
    await tester.tap(find.text('TEST-SERVER'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('Geräte-ID: 123456789'), findsOneWidget);
    expect(find.text('Own › Servers'), findsOneWidget);
    await tester.tap(find.text('Verbinden'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(opened, 'g3fernwartung://123456789');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Narrow view stays usable and logout removes saved login',
      (tester) async {
    tester.view.physicalSize = const Size(430, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final credentials = FixtureCredentials();
    final api = G3AddressBookApi(
        client: MockClient((request) async => http.Response(
            jsonEncode(request.url.path.endsWith('/logout')
                ? {'logged_out': true}
                : tree),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: G3AddressBook(
                api: api, credentials: credentials, onConnect: (_) async {}))));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'TEST');
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TEST-SERVER'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('Verbinden'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Abmelden'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(credentials.deleted, isTrue);
    expect(find.text('Mit g3 anmelden'), findsOneWidget);
    expect(find.text('TEST-SERVER'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Revoked login clears remembered authority', (tester) async {
    final credentials = FixtureCredentials();
    final api = G3AddressBookApi(
        client: MockClient((_) async => http.Response('{}', 401)));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: G3AddressBook(
                api: api, credentials: credentials, onConnect: (_) async {}))));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(credentials.deleted, isTrue);
    expect(find.textContaining('widerrufen'), findsOneWidget);
    expect(find.text('Mit g3 anmelden'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('Edits device metadata without replacing the saved password',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final editable = jsonDecode(jsonEncode(tree)) as Map<String, dynamic>;
    editable['capabilities'] = {
      'can_create_root': true,
      'can_move_devices': true,
      'can_delete_devices': true
    };
    for (final book in editable['books']) {
      book.addAll({'can_edit': true, 'can_add_book': true, 'can_reveal': true});
    }
    Map<String, dynamic>? saved;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/devices/7')) {
        return http.Response(
            jsonEncode({
              'id': 7,
              'customer_id': 3,
              'name': 'TEST-SERVER',
              'rustdesk_id': '123456789',
              'notes': 'Old',
              'username': 'fixture',
              'can_reveal': true,
              'has_credential': true
            }),
            200);
      }
      if (request.url.path.endsWith('/devices/save')) {
        saved = jsonDecode(request.body) as Map<String, dynamic>;
        editable['devices'][0]['name'] = saved!['name'];
        return http.Response('{"saved":true,"id":7}', 200);
      }
      return http.Response(jsonEncode(editable), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: G3AddressBook(
                api: G3AddressBookApi(client: client),
                credentials: FixtureCredentials(),
                onConnect: (_) async {}))));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '123456789');
    await tester.pumpAndSettle();
    await tester.tap(find.text('TEST-SERVER'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bearbeiten'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Edited server');
    await tester.tap(find.text('Speichern'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
    expect(saved?['name'], 'Edited server');
    expect(saved?['credential'], '');
    expect(saved?['clear_credential'], false);
    expect(find.text('Edited server'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Creates an address book through the client toolbar',
      (tester) async {
    final editable = jsonDecode(jsonEncode(tree)) as Map<String, dynamic>;
    editable['capabilities'] = {'can_create_root': true};
    Map<String, dynamic>? saved;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/books/save')) {
        saved = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{"saved":true,"id":9}', 200);
      }
      return http.Response(jsonEncode(editable), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: G3AddressBook(
                api: G3AddressBookApi(client: client),
                credentials: FixtureCredentials(),
                onConnect: (_) async {}))));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Adressbuch hinzufügen'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextFormField).first, 'New address book');
    await tester.tap(find.text('Speichern'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
    expect(saved?['name'], 'New address book');
    expect(saved?['parent_id'], isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
