import 'package:flutter/material.dart';
import 'g3_addressbook_api.dart';

Future<bool> g3DeleteEntry(BuildContext context, G3AddressBookApi api,
    String kind, int id, String name) async {
  final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
            title: const Text('Eintrag löschen?'),
            content: Text('„$name“ aus dem Adressbuch löschen?'
                '${kind == 'devices' ? '\nDas entfernte Gerät wird nicht deinstalliert.' : '\nNur leere, selbst angelegte Adressbücher können gelöscht werden.'}'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Abbrechen')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Löschen')),
            ],
          ));
  if (confirmed != true) return false;
  await api.request('$kind/delete', body: {'id': id});
  return true;
}

class G3AddressBookEditor extends StatefulWidget {
  final G3AddressBookApi api;
  final List<Map<String, dynamic>> books;
  final Map<String, dynamic>? entry;
  final int? parentId;
  final bool device, canCreateRoot, canMove;
  const G3AddressBookEditor(
      {super.key,
      required this.api,
      required this.books,
      this.entry,
      this.parentId,
      required this.device,
      this.canCreateRoot = false,
      this.canMove = false});
  @override
  State<G3AddressBookEditor> createState() => _G3AddressBookEditorState();
}

class _G3AddressBookEditorState extends State<G3AddressBookEditor> {
  final form = GlobalKey<FormState>();
  late final name =
      TextEditingController(text: widget.entry?['name'] as String? ?? '');
  late final id = TextEditingController(
      text: widget.entry?['rustdesk_id'] as String? ?? '');
  late final notes =
      TextEditingController(text: widget.entry?['notes'] as String? ?? '');
  late final username =
      TextEditingController(text: widget.entry?['username'] as String? ?? '');
  final password = TextEditingController();
  late final editable =
      widget.books.where((b) => b['can_edit'] == true).toList();
  late int? bookId = widget.entry?['customer_id'] as int? ??
      widget.parentId ??
      (widget.device && editable.isNotEmpty
          ? editable.first['id'] as int
          : null);
  bool saving = false, clearCredential = false;
  String? error;

  @override
  void dispose() {
    for (final controller in [name, id, notes, username, password]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (saving || !form.currentState!.validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final data = <String, dynamic>{'name': name.text.trim()};
      if (widget.entry != null) data['id'] = widget.entry!['id'];
      if (widget.device) {
        final book = editable.firstWhere((b) => b['id'] == bookId);
        data.addAll({
          'customer_id': bookId,
          'rustdesk_id': id.text,
          'notes': notes.text
        });
        if (book['can_reveal'] == true) {
          data.addAll({
            'username': username.text,
            'credential': clearCredential ? '' : password.text,
            'clear_credential': clearCredential
          });
        }
      } else if (widget.entry == null) {
        data['parent_id'] = bookId;
      }
      await widget.api
          .request('${widget.device ? 'devices' : 'books'}/save', body: data);
      if (mounted) Navigator.pop(context, true);
    } on G3AddressBookExpired {
      if (mounted) Navigator.pop(context, false);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final reveal = widget.device &&
        editable.any((b) => b['id'] == bookId && b['can_reveal'] == true);
    return PopScope(
        canPop: !saving,
        child: AlertDialog(
          title: Text(
              '${widget.device ? 'Gerät' : 'Adressbuch'} ${widget.entry == null ? 'hinzufügen' : 'bearbeiten'}'),
          content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                  child: Form(
                      key: form,
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (error != null)
                              Text(error!,
                                  style: TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.error)),
                            TextFormField(
                                controller: name,
                                autofocus: true,
                                maxLength: 200,
                                decoration:
                                    const InputDecoration(labelText: 'Name'),
                                validator: (v) => v == null || v.trim().isEmpty
                                    ? 'Bitte einen Namen eingeben.'
                                    : null),
                            if (widget.device || widget.entry == null)
                              DropdownButtonFormField<int>(
                                  value: bookId ?? 0,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                      labelText: widget.device
                                          ? 'Adressbuch'
                                          : 'Übergeordnetes Adressbuch'),
                                  items: [
                                    if (!widget.device && widget.canCreateRoot)
                                      const DropdownMenuItem(
                                          value: 0,
                                          child: Text('Oberste Ebene')),
                                    ...editable
                                        .where((b) =>
                                            widget.device ||
                                            b['can_add_book'] == true)
                                        .map((b) => DropdownMenuItem<int>(
                                            value: b['id'] as int,
                                            child: Text(b['path'] as String,
                                                overflow:
                                                    TextOverflow.ellipsis))),
                                  ],
                                  onChanged: saving ||
                                          (widget.device &&
                                              widget.entry != null &&
                                              !widget.canMove)
                                      ? null
                                      : (value) => setState(() =>
                                          bookId = value == 0 ? null : value),
                                  validator: (_) =>
                                      widget.device && bookId == null
                                          ? 'Adressbuch auswählen.'
                                          : null),
                            if (widget.device) ...[
                              TextFormField(
                                  controller: id,
                                  maxLength: 40,
                                  decoration: const InputDecoration(
                                      labelText: 'Geräte-ID'),
                                  validator: (v) => RegExp(
                                              r'^[A-Za-z0-9_-]{6,32}$')
                                          .hasMatch((v ?? '')
                                              .replaceAll(RegExp(r'\s+'), ''))
                                      ? null
                                      : 'Bitte eine gültige Geräte-ID eingeben.'),
                              TextFormField(
                                  controller: notes,
                                  maxLength: 4000,
                                  minLines: 2,
                                  maxLines: 4,
                                  decoration: const InputDecoration(
                                      labelText: 'Notizen')),
                              if (reveal) ...[
                                TextFormField(
                                    controller: username,
                                    maxLength: 200,
                                    decoration: const InputDecoration(
                                        labelText: 'Benutzername')),
                                TextFormField(
                                    controller: password,
                                    obscureText: true,
                                    enableSuggestions: false,
                                    autocorrect: false,
                                    enabled: !clearCredential,
                                    maxLength: 4096,
                                    decoration: InputDecoration(
                                        labelText: 'Neues Gerätekennwort',
                                        helperText: widget.entry == null
                                            ? 'Optional'
                                            : 'Leer lassen, um das gespeicherte Kennwort zu behalten.')),
                                if (widget.entry?['has_credential'] == true)
                                  CheckboxListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text(
                                          'Gespeichertes Gerätekennwort entfernen'),
                                      value: clearCredential,
                                      onChanged: saving
                                          ? null
                                          : (v) => setState(() =>
                                              clearCredential = v ?? false)),
                              ] else
                                const Text(
                                    'Anmeldedaten bleiben unverändert. Dafür fehlt das Enthüllungsrecht.'),
                            ],
                          ])))),
          actions: [
            TextButton(
                onPressed: saving ? null : () => Navigator.pop(context, false),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: saving ? null : save,
                child: Text(saving ? 'Speichern …' : 'Speichern')),
          ],
        ));
  }
}
