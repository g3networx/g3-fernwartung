import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'g3_local_addressbook_store.dart';
import 'g3_local_addressbook_crypto.dart';
import 'g3_local_addressbook_password_dialog.dart';

class G3AddressBooks extends StatefulWidget {
  final Widget remote;
  final Future<void> Function(String id, bool files, String password)
      onLocalConnect;
  const G3AddressBooks(
      {super.key, required this.remote, required this.onLocalConnect});

  @override
  State<G3AddressBooks> createState() => _G3AddressBooksState();
}

class _G3AddressBooksState extends State<G3AddressBooks> {
  int selected = 0;
  final localKey = GlobalKey<_G3LocalAddressBookState>();
  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Column(children: [
          TabBar(
              onTap: (index) {
                setState(() => selected = index);
                if (index == 1) localKey.currentState?.load();
              },
              tabs: const [
                Tab(text: 'g3-Adressbuch'),
                Tab(text: 'Lokales Adressbuch')
              ]),
          Expanded(
              child: IndexedStack(index: selected, children: [
            widget.remote,
            G3LocalAddressBook(key: localKey, onConnect: widget.onLocalConnect)
          ])),
        ]),
      );
}

class G3LocalAddressBook extends StatefulWidget {
  final Future<void> Function(String id, bool files, String password) onConnect;
  final G3LocalAddressBookStore? store;
  const G3LocalAddressBook({super.key, required this.onConnect, this.store});
  @override
  State<G3LocalAddressBook> createState() => _G3LocalAddressBookState();
}

class _G3LocalAddressBookState extends State<G3LocalAddressBook> {
  G3LocalAddressBookStore? store;
  List<G3LocalEntry> entries = [];
  List<String> books = [];
  String? selectedBook;
  String query = '';
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'Der Vorgang konnte nicht abgeschlossen werden. Vorhandene Einträge bleiben erhalten.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load() => run(() async {
        store ??= widget.store ?? G3LocalAddressBookStore.forCurrentPc();
        final data = await store!.read();
        final paths = await store!.readBooks();
        if (mounted) {
          setState(() {
            entries = data;
            books = paths;
            if (selectedBook != '' && !books.contains(selectedBook)) {
              selectedBook = null;
            }
          });
        }
      });

  Future<void> reload() async {
    final data = await store!.read();
    final paths = await store!.readBooks();
    if (mounted) {
      setState(() {
        entries = data;
        books = paths;
        if (selectedBook != '' && !books.contains(selectedBook)) {
          selectedBook = null;
        }
      });
    }
  }

  Future<void> addBook() async {
    var parent = selectedBook ?? '';
    var name = '';
    final form = GlobalKey<FormState>();
    final path = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Lokales Unteradressbuch hinzufügen'),
                content: SizedBox(
                    width: 440,
                    child: Form(
                        key: form,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          DropdownButtonFormField<String>(
                              value: parent,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                  labelText: 'Übergeordnetes Adressbuch'),
                              items: [
                                const DropdownMenuItem(
                                    value: '',
                                    child: Text('Lokales Adressbuch')),
                                ...books.map((b) =>
                                    DropdownMenuItem(value: b, child: Text(b)))
                              ],
                              onChanged: (value) => parent = value ?? ''),
                          TextFormField(
                              autofocus: true,
                              maxLength: 80,
                              decoration: const InputDecoration(
                                  labelText: 'Adressbuchname'),
                              onChanged: (value) => name = value.trim(),
                              validator: (_) => name.isEmpty ||
                                      name.contains('/') ||
                                      !G3LocalAddressBookStore.validBook(
                                          parent.isEmpty
                                              ? name
                                              : '$parent/$name')
                                  ? 'Bitte einen gültigen Namen eingeben (maximal 8 Ebenen).'
                                  : null),
                        ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () {
                        if (form.currentState!.validate()) {
                          Navigator.pop(
                              context, parent.isEmpty ? name : '$parent/$name');
                        }
                      },
                      child: const Text('Anlegen'))
                ]));
    if (path != null && mounted) {
      await run(() async {
        await store!.addBook(path);
        await reload();
        if (mounted) setState(() => selectedBook = path);
      });
    }
  }

  Future<void> removeBook() async {
    final path = selectedBook;
    if (path == null || path.isEmpty) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Lokales Adressbuch löschen?'),
                content: Text(
                    '„$path“ löschen? Nur leere Adressbücher ohne Unteradressbücher können entfernt werden.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Löschen'))
                ]));
    if (confirmed == true && mounted) {
      await run(() async {
        await store!.removeBook(path);
        await reload();
      });
    }
  }

  Future<void> edit([G3LocalEntry? entry]) async {
    final form = GlobalKey<FormState>();
    var name = entry?.name ?? '';
    var id = entry?.id ?? '';
    var group = entry?.group ?? '';
    var book = entry?.book ?? selectedBook ?? '';
    var notes = entry?.notes ?? '';
    var password = '';
    var removePassword = false;
    final value = await showDialog<G3LocalEntry>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, updateDialog) => AlertDialog(
                  title: Text(entry == null
                      ? 'Lokalen Eintrag hinzufügen'
                      : 'Lokalen Eintrag bearbeiten'),
                  content: SizedBox(
                      width: 440,
                      child: SingleChildScrollView(
                          child: Form(
                              key: form,
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TextFormField(
                                        initialValue: name,
                                        onSaved: (value) =>
                                            name = (value ?? '').trim(),
                                        autofocus: true,
                                        maxLength: 160,
                                        decoration: const InputDecoration(
                                            labelText: 'Name'),
                                        validator: (v) =>
                                            (v ?? '').trim().isEmpty
                                                ? 'Bitte einen Namen eingeben.'
                                                : null),
                                    TextFormField(
                                        initialValue: id,
                                        onSaved: (value) =>
                                            id = (value ?? '').trim(),
                                        maxLength: 40,
                                        decoration: const InputDecoration(
                                            labelText: 'Geräte-ID'),
                                        validator: (v) => RegExp(
                                                    r'^[A-Za-z0-9_-]{6,40}$')
                                                .hasMatch((v ?? '').trim())
                                            ? null
                                            : 'Bitte eine gültige Geräte-ID eingeben.'),
                                    TextFormField(
                                        initialValue: group,
                                        onSaved: (value) =>
                                            group = (value ?? '').trim(),
                                        maxLength: 160,
                                        decoration: const InputDecoration(
                                            labelText: 'Gruppe (optional)')),
                                    DropdownButtonFormField<String>(
                                        value: book,
                                        isExpanded: true,
                                        decoration: const InputDecoration(
                                            labelText: 'Lokales Adressbuch'),
                                        items: [
                                          const DropdownMenuItem(
                                              value: '',
                                              child: Text('Oberste Ebene')),
                                          ...books.map((b) => DropdownMenuItem(
                                              value: b, child: Text(b)))
                                        ],
                                        onChanged: (value) =>
                                            book = value ?? ''),
                                    TextFormField(
                                        initialValue: notes,
                                        onSaved: (value) =>
                                            notes = (value ?? '').trim(),
                                        maxLength: 2000,
                                        minLines: 2,
                                        maxLines: 4,
                                        decoration: const InputDecoration(
                                            labelText: 'Notiz (optional)')),
                                    TextFormField(
                                        obscureText: true,
                                        autocorrect: false,
                                        enableSuggestions: false,
                                        enabled: !removePassword,
                                        maxLength: 1024,
                                        onSaved: (value) =>
                                            password = value ?? '',
                                        decoration: InputDecoration(
                                            labelText:
                                                'Verbindungskennwort (optional)',
                                            helperText: entry?.passwordProtected
                                                        .isNotEmpty ==
                                                    true
                                                ? 'Leer lassen, um das gespeicherte Kennwort beizubehalten.'
                                                : 'Wird für diesen Windows-Benutzer verschlüsselt gespeichert.')),
                                    if (entry?.passwordProtected.isNotEmpty ==
                                        true)
                                      CheckboxListTile(
                                          contentPadding: EdgeInsets.zero,
                                          title: const Text(
                                              'Gespeichertes Kennwort entfernen'),
                                          value: removePassword,
                                          onChanged: (value) => updateDialog(
                                              () => removePassword =
                                                  value ?? false)),
                                  ])))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Abbrechen')),
                    FilledButton(
                        onPressed: () {
                          if (form.currentState!.validate()) {
                            form.currentState!.save();
                            Navigator.pop(
                                context,
                                G3LocalEntry(
                                    id: id,
                                    name: name,
                                    group: group,
                                    book: book,
                                    notes: notes));
                          }
                        },
                        child: const Text('Speichern')),
                  ],
                )));
    if (value != null && mounted) {
      await run(() async {
        await store!.put(value,
            previousId: entry?.id,
            password: password.isEmpty ? null : password,
            removePassword: removePassword);
        password = '';
        await reload();
      });
    }
  }

  Future<void> remove(G3LocalEntry entry) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Lokalen Eintrag löschen?'),
              content: Text(
                  '„${entry.name}“ wird nur aus diesem lokalen Adressbuch entfernt.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Abbrechen')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Löschen'))
              ],
            ));
    if (confirmed == true && mounted) {
      await run(() async {
        await store!.remove(entry.id);
        await reload();
      });
    }
  }

  Future<void> importBook() => run(() async {
        final result = await FilePicker.platform
            .pickFiles(type: FileType.custom, allowedExtensions: ['json']);
        if (result == null || !mounted) return;
        final path = result.files.single.path;
        if (path == null) {
          throw const FormatException(
              'Die ausgewählte Datei ist nicht verfügbar.');
        }
        final file = File(path);
        if (await file.length() > G3LocalBookExportCipher.maxFileBytes) {
          throw const FormatException(
              'Die Exportdatei ist zu groß (maximal 4 MB).');
        }
        var text = await file.readAsString();
        if (text.startsWith('\uFEFF')) text = text.substring(1);
        final header = jsonDecode(text);
        List<G3LocalEntry> imported;
        List<String> importedBooks;
        if (header is Map &&
            header['format'] == 'g3-local-addressbook' &&
            header['version'] == 1) {
          imported = G3LocalAddressBookStore.decode(text);
          importedBooks = G3LocalAddressBookStore.decodeBooks(text);
        } else if (header is Map &&
            header['format'] == G3LocalBookExportCipher.format) {
          if (!mounted) return;
          final password =
              await showG3LocalExportPassword(context, exporting: false);
          if (password == null) return;
          final book = await store!.openEncryptedBook(text, password);
          imported = book.entries;
          importedBooks = book.books;
        } else {
          throw const FormatException(
              'Bitte eine Exportdatei aus dem lokalen Adressbuch auswählen.');
        }
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  title: const Text('Lokales Adressbuch importieren'),
                  content: Text(
                      '${imported.length} Einträge und ${importedBooks.length} lokale Adressbücher einlesen? Vorhandene Geräte-IDs werden übersprungen. Bestehende Einträge werden nicht überschrieben.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Abbrechen')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Importieren'))
                  ],
                ));
        if (confirmed != true || !mounted) return;
        final added =
            await store!.importEntries(imported, books: importedBooks);
        await reload();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  '$added Einträge importiert, ${imported.length - added} vorhandene übersprungen.')));
        }
      });

  Future<void> exportBook() => run(() async {
        final password =
            await showG3LocalExportPassword(context, exporting: true);
        if (password == null) return;
        final path = await FilePicker.platform.saveFile(
            dialogTitle: 'Lokales Adressbuch exportieren',
            fileName: 'g3-lokales-adressbuch.json',
            type: FileType.custom,
            allowedExtensions: ['json']);
        if (path == null) return;
        if (File(path).absolute.path.toLowerCase() ==
                store!.file.absolute.path.toLowerCase() ||
            (await File(path).exists() &&
                await store!.file.exists() &&
                await FileSystemEntity.identical(path, store!.file.path))) {
          throw const FormatException(
              'Bitte eine separate Exportdatei auswählen.');
        }
        final encrypted = await store!.encryptedExport(password);
        await File(path).writeAsString(encrypted, flush: true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Lokales Adressbuch exportiert.')));
        }
      });

  Future<void> connectEntry(G3LocalEntry entry, bool files) => run(() async {
        final password = await store!.passwordFor(entry);
        await widget.onConnect(entry.id, files, password);
      });

  @override
  Widget build(BuildContext context) {
    final filtered = entries
        .where((e) => selectedBook == null || e.book == selectedBook)
        .where((e) => '${e.name} ${e.id} ${e.group} ${e.notes} ${e.book}'
            .toLowerCase()
            .contains(query.toLowerCase()))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
              'Nur auf diesem PC im aktuellen Windows-Benutzerprofil gespeichert. Keine Synchronisierung mit dem g3-Adressbuch.'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            FilledButton.icon(
                onPressed: busy || store == null ? null : () => edit(),
                icon: const Icon(Icons.add),
                label: const Text('Hinzufügen')),
            OutlinedButton.icon(
                onPressed: busy || store == null ? null : addBook,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Unteradressbuch')),
            OutlinedButton.icon(
                onPressed: busy || store == null ? null : importBook,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Importieren')),
            OutlinedButton.icon(
                onPressed: busy || store == null ? null : exportBook,
                icon: const Icon(Icons.save_alt),
                label: const Text('Exportieren')),
            IconButton(
                tooltip: 'Neu laden',
                onPressed: busy ? null : load,
                icon: const Icon(Icons.refresh)),
          ]),
          Row(children: [
            Expanded(
                child: DropdownButtonFormField<String>(
                    value: selectedBook ?? '\u0000all',
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'Lokales Adressbuch anzeigen'),
                    items: [
                      const DropdownMenuItem(
                          value: '\u0000all',
                          child: Text('Alle lokalen Einträge')),
                      const DropdownMenuItem(
                          value: '', child: Text('Oberste Ebene')),
                      ...books.map(
                          (b) => DropdownMenuItem(value: b, child: Text(b)))
                    ],
                    onChanged: busy
                        ? null
                        : (value) => setState(() => selectedBook =
                            value == '\u0000all' ? null : value))),
            if (selectedBook != null && selectedBook!.isNotEmpty)
              IconButton(
                  tooltip: 'Leeres lokales Adressbuch löschen',
                  onPressed: busy ? null : removeBook,
                  icon: const Icon(Icons.folder_delete_outlined)),
          ]),
          TextField(
              onChanged: (value) => setState(() => query = value),
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Name, Geräte-ID, Gruppe oder Notiz suchen')),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(query.isEmpty
                          ? 'Keine Einträge in dieser Ansicht. Über „Hinzufügen“ oder „Importieren“ beginnen.'
                          : 'Keine passenden Einträge.'))
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final entry = filtered[index];
                        return ListTile(
                            title: Text(entry.name),
                            subtitle: Text(
                                [
                                  entry.id,
                                  if (entry.book.isNotEmpty) entry.book,
                                  if (entry.group.isNotEmpty) entry.group,
                                  if (entry.notes.isNotEmpty) entry.notes
                                ].join(' · '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                            trailing:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(
                                  tooltip: 'Desktop verbinden',
                                  onPressed: busy
                                      ? null
                                      : () => connectEntry(entry, false),
                                  icon: const Icon(Icons.desktop_windows)),
                              PopupMenuButton<String>(
                                  enabled: !busy,
                                  tooltip: 'Weitere Aktionen',
                                  onSelected: (action) {
                                    if (action == 'edit') edit(entry);
                                    if (action == 'delete') remove(entry);
                                    if (action == 'files') {
                                      connectEntry(entry, true);
                                    }
                                  },
                                  itemBuilder: (_) => const [
                                        PopupMenuItem(
                                            value: 'files',
                                            child: Text('Dateiexplorer')),
                                        PopupMenuItem(
                                            value: 'edit',
                                            child: Text('Bearbeiten')),
                                        PopupMenuItem(
                                            value: 'delete',
                                            child: Text('Löschen'))
                                      ]),
                            ]));
                      },
                    )),
        ]));
  }
}
