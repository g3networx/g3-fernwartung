import 'package:flutter/material.dart';
import 'g3_local_addressbook_store.dart';

Future<void> showG3CopyToLocalBook(BuildContext context,
    {required String id,
    required String name,
    G3LocalAddressBookStore? store}) async {
  final local = store ?? G3LocalAddressBookStore.forCurrentPc();
  final books = await local.readBooks();
  if (!context.mounted) return;
  var destination = '';
  var localName = name;
  var password = '';
  final form = GlobalKey<FormState>();
  final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
              title: const Text('In lokales Adressbuch kopieren'),
              content: SizedBox(
                  width: 440,
                  child: SingleChildScrollView(
                      child: Form(
                          key: form,
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Geräte-ID: $id'),
                                const Text(
                                    'Der öffentliche Eintrag bleibt erhalten. Serverkennwörter und Verbindungsfreigaben werden nicht kopiert. Ein eigenes Verbindungskennwort kann hier verschlüsselt hinterlegt werden.'),
                                TextFormField(
                                    initialValue: name,
                                    maxLength: 160,
                                    decoration: const InputDecoration(
                                        labelText: 'Lokaler Name'),
                                    onSaved: (value) =>
                                        localName = (value ?? '').trim(),
                                    validator: (value) => (value ?? '')
                                                .trim()
                                                .isEmpty ||
                                            (value ?? '').length > 160
                                        ? 'Bitte einen Namen mit maximal 160 Zeichen eingeben.'
                                        : null),
                                DropdownButtonFormField<String>(
                                    value: destination,
                                    isExpanded: true,
                                    decoration: const InputDecoration(
                                        labelText: 'Lokales Zieladressbuch'),
                                    items: [
                                      const DropdownMenuItem(
                                          value: '',
                                          child: Text('Oberste Ebene')),
                                      ...books.map((b) => DropdownMenuItem(
                                          value: b, child: Text(b)))
                                    ],
                                    onChanged: (value) =>
                                        destination = value ?? ''),
                                TextFormField(
                                    obscureText: true,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    maxLength: 1024,
                                    decoration: const InputDecoration(
                                        labelText:
                                            'Verbindungskennwort (optional)'),
                                    onSaved: (value) => password = value ?? ''),
                              ])))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Abbrechen')),
                FilledButton(
                    onPressed: () {
                      if (form.currentState!.validate()) {
                        form.currentState!.save();
                        Navigator.pop(context, true);
                      }
                    },
                    child: const Text('Kopieren'))
              ]));
  if (confirmed != true) return;
  try {
    await local.put(G3LocalEntry(id: id, name: localName, book: destination),
        password: password.isEmpty ? null : password);
  } finally {
    password = '';
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Eintrag ins lokale Adressbuch kopiert.')));
  }
}
