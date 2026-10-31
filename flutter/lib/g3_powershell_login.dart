import 'package:flutter/material.dart';

/// One connection only. Never persist Windows credentials or include them in URIs.
class G3PowerShellLogin {
  G3PowerShellLogin(this.username, this.password);
  final String username;
  String password;
  void clear() => password = '';
}

Future<G3PowerShellLogin?> showG3PowerShellLogin(BuildContext context) =>
    showDialog<G3PowerShellLogin>(context: context, builder: (_) => const _G3PowerShellLoginDialog());

class _G3PowerShellLoginDialog extends StatefulWidget {
  const _G3PowerShellLoginDialog();
  @override
  State<_G3PowerShellLoginDialog> createState() => _G3PowerShellLoginDialogState();
}

class _G3PowerShellLoginDialogState extends State<_G3PowerShellLoginDialog> {
  final username = TextEditingController();
  final password = TextEditingController();
  final form = GlobalKey<FormState>();
  var administrator = true;
  @override
  void dispose() {
    username.clear(); password.clear(); username.dispose(); password.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
          title: const Text('PowerShell verbinden'),
          content: SizedBox(width: 440, child: SingleChildScrollView(child: Form(
            key: form,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<bool>(
                isExpanded: true,
                value: administrator,
                decoration: const InputDecoration(labelText: 'Ausführen als'),
                items: const [
                  DropdownMenuItem(value: true, child: Text('Administrator (SYSTEM)')),
                  DropdownMenuItem(value: false, child: Text('Angemeldeter Windows-Benutzer')),
                ],
                onChanged: (value) => setState(() => administrator = value == true),
              ),
              const SizedBox(height: 16),
              if (administrator) ...[
                TextFormField(
                  controller: username,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Windows-/AD-Administratorkonto', hintText: r'DOMÄNE\Benutzer oder benutzer@domäne'),
                  validator: (value) => value == null || value.trim().isEmpty ? 'Benutzer angeben' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: password,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Windows-Kennwort'),
                  validator: (value) => value == null || value.isEmpty ? 'Kennwort angeben' : null,
                ),
                const SizedBox(height: 16),
                const Text('Das Konto muss auf dem Zielgerät Administrator sein. Nach erfolgreicher Prüfung läuft die Shell als SYSTEM, nicht unter der eingegebenen Benutzeridentität. Das Kennwort wird nur für diese Verbindung verwendet.'),
              ] else
                const Padding(padding: EdgeInsets.only(top: 8), child: Text('Die Shell läuft mit den Rechten des auf dem Zielgerät angemeldeten Windows-Benutzers. Es erfolgt keine Erhöhung.')),
            ]),
          ))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
            FilledButton(onPressed: () {
              if (!administrator || form.currentState!.validate()) {
                Navigator.pop(context, G3PowerShellLogin(administrator ? username.text.trim() : '', administrator ? password.text : ''));
              }
            }, child: const Text('Verbinden')),
          ],
        );

  }
}
