import 'package:flutter/material.dart';

Future<String?> showG3LocalExportPassword(BuildContext context,
    {required bool exporting}) {
  final form = GlobalKey<FormState>();
  var password = '';
  return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
            title: Text(
                exporting ? 'Export verschlüsseln' : 'Exportkennwort eingeben'),
            content: SizedBox(
                width: 420,
                child: Form(
                    key: form,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(exporting
                          ? 'Dieses Kennwort wird zum Import auf einem anderen PC benötigt. Ohne das Kennwort lässt sich die Exportdatei nicht öffnen.'
                          : 'Bitte das Kennwort eingeben, mit dem diese Exportdatei verschlüsselt wurde.'),
                      const SizedBox(height: 12),
                      TextFormField(
                          autofocus: true,
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          maxLength: 1024,
                          decoration: const InputDecoration(
                              labelText: 'Exportkennwort'),
                          onChanged: (value) => password = value,
                          validator: (value) =>
                              (value ?? '').length < (exporting ? 12 : 1)
                                  ? (exporting
                                      ? 'Bitte mindestens 12 Zeichen verwenden.'
                                      : 'Bitte das Exportkennwort eingeben.')
                                  : null),
                      if (exporting)
                        TextFormField(
                            obscureText: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            maxLength: 1024,
                            decoration: const InputDecoration(
                                labelText: 'Exportkennwort wiederholen'),
                            validator: (value) => value != password
                                ? 'Die Kennwörter stimmen nicht überein.'
                                : null),
                    ]))),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Abbrechen')),
              FilledButton(
                  onPressed: () {
                    if (form.currentState!.validate()) {
                      Navigator.pop(context, password);
                    }
                  },
                  child: Text(exporting ? 'Weiter' : 'Entschlüsseln'))
            ],
          ));
}
