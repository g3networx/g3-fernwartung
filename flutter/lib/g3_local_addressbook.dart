import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'g3_local_addressbook_store.dart';

class G3AddressBooks extends StatefulWidget {
  final Widget remote;
  final Future<void> Function(String id, bool files) onLocalConnect;
  const G3AddressBooks(
      {super.key, required this.remote, required this.onLocalConnect});

  @override
  State<G3AddressBooks> createState() => _G3AddressBooksState();
}

class _G3AddressBooksState extends State<G3AddressBooks> {
  int selected = 0;
  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Column(children: [
          TabBar(
              onTap: (index) => setState(() => selected = index),
              tabs: const [
                Tab(text: 'g3-Adressbuch'),
                Tab(text: 'Lokales Adressbuch')
              ]),
          Expanded(
              child: IndexedStack(index: selected, children: [
            widget.remote,
            G3LocalAddressBook(onConnect: widget.onLocalConnect)
          ])),
        ]),
      );
}

class G3LocalAddressBook extends StatefulWidget {
  final Future<void> Function(String id, bool files) onConnect;
  final G3LocalAddressBookStore? store;
  const G3LocalAddressBook({super.key, required this.onConnect, this.store});
  @override
  State<G3LocalAddressBook> createState() => _G3LocalAddressBookState();
}

class _G3LocalAddressBookState extends State<G3LocalAddressBook> {
  G3LocalAddressBookStore? store;
  List<G3LocalEntry> entries = [];
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
        if (mounted) setState(() => entries = data);
      });

  Future<void> reload() async {
    final data = await store!.read();
    if (mounted) setState(() => entries = data);
  }

  Future<void> edit([G3LocalEntry? entry]) async {
    final form = GlobalKey<FormState>();
    var name = entry?.name ?? '';
    var id = entry?.id ?? '';
    var group = entry?.group ?? '';
    var notes = entry?.notes ?? '';
    final value = await showDialog<G3LocalEntry>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(entry == null
                  ? 'Lokalen Eintrag hinzufügen'
                  : 'Lokalen Eintrag bearbeiten'),
              content: SizedBox(
                  width: 440,
                  child: SingleChildScrollView(
                      child: Form(
                          key: form,
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            TextFormField(
                                initialValue: name,
                                onSaved: (value) => name = (value ?? '').trim(),
                                autofocus: true,
                                maxLength: 160,
                                decoration:
                                    const InputDecoration(labelText: 'Name'),
                                validator: (v) => (v ?? '').trim().isEmpty
                                    ? 'Bitte einen Namen eingeben.'
                                    : null),
                            TextFormField(
                                initialValue: id,
                                onSaved: (value) => id = (value ?? '').trim(),
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
                            TextFormField(
                                initialValue: notes,
                                onSaved: (value) =>
                                    notes = (value ?? '').trim(),
                                maxLength: 2000,
                                minLines: 2,
                                maxLines: 4,
                                decoration: const InputDecoration(
                                    labelText: 'Notiz (optional)')),
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
                                notes: notes));
                      }
                    },
                    child: const Text('Speichern')),
              ],
            ));
    if (value != null && mounted) {
      await run(() async {
        await store!.put(value, previousId: entry?.id);
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
        if (await file.length() > G3LocalAddressBookStore.maxBytes) {
          throw const FormatException('Die Datei ist zu groß (maximal 2 MB).');
        }
        final imported =
            G3LocalAddressBookStore.decode(await file.readAsString());
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  title: const Text('Lokales Adressbuch importieren'),
                  content: Text(
                      '${imported.length} Einträge einlesen? Vorhandene Geräte-IDs werden übersprungen. Bestehende Einträge werden nicht überschrieben.'),
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
        final added = await store!.importEntries(imported);
        await reload();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  '$added Einträge importiert, ${imported.length - added} vorhandene übersprungen.')));
        }
      });

  Future<void> exportBook() => run(() async {
        final data = await store!.read();
        final path = await FilePicker.platform.saveFile(
            dialogTitle: 'Lokales Adressbuch exportieren',
            fileName: 'g3-lokales-adressbuch.json',
            type: FileType.custom,
            allowedExtensions: ['json']);
        if (path == null) return;
        if (File(path).absolute.path.toLowerCase() ==
            store!.file.absolute.path.toLowerCase()) {
          throw const FormatException(
              'Bitte eine separate Exportdatei auswählen.');
        }
        await File(path)
            .writeAsString(G3LocalAddressBookStore.encode(data), flush: true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Lokales Adressbuch exportiert.')));
        }
      });

  @override
  Widget build(BuildContext context) {
    final filtered = entries
        .where((e) => '${e.name} ${e.id} ${e.group} ${e.notes}'
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
                          ? 'Noch keine lokalen Einträge. Über „Hinzufügen“ oder „Importieren“ beginnen.'
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
                                      : () => run(() =>
                                          widget.onConnect(entry.id, false)),
                                  icon: const Icon(Icons.desktop_windows)),
                              PopupMenuButton<String>(
                                  enabled: !busy,
                                  tooltip: 'Weitere Aktionen',
                                  onSelected: (action) {
                                    if (action == 'edit') edit(entry);
                                    if (action == 'delete') remove(entry);
                                    if (action == 'files') {
                                      run(() =>
                                          widget.onConnect(entry.id, true));
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
