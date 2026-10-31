import 'package:flutter/material.dart';
import 'g3_powershell_credentials.dart';

class G3PowerShellLogin {
  G3PowerShellLogin(this.username, this.password, {this.remember = false});
  final String username;
  String password;
  final bool remember;
  void clear() => password = '';
}

Future<G3PowerShellLogin?> showG3PowerShellLogin(BuildContext context,
    {String deviceId = '', G3PowerShellCredentials? credentials}) async {
  final store = credentials ?? G3PowerShellCredentials();
  Map<String, String>? saved;
  var readFailed = false;
  try {saved = await store.read(deviceId);} catch (_) {readFailed = true;}
  try {
    if (!context.mounted) return null;
    return await showDialog<G3PowerShellLogin>(context: context, builder: (_) =>
      _G3PowerShellLoginDialog(deviceId: deviceId, store: store, saved: saved, readFailed: readFailed));
  } finally {saved?.clear();}
}

class _G3PowerShellLoginDialog extends StatefulWidget {
  const _G3PowerShellLoginDialog({required this.deviceId, required this.store, required this.saved, required this.readFailed});
  final String deviceId;
  final G3PowerShellCredentials store;
  final Map<String, String>? saved;
  final bool readFailed;
  @override
  State<_G3PowerShellLoginDialog> createState() => _G3PowerShellLoginDialogState();
}

class _G3PowerShellLoginDialogState extends State<_G3PowerShellLoginDialog> {
  final username = TextEditingController();
  final password = TextEditingController();
  final form = GlobalKey<FormState>();
  var remember = false, hasSaved = false;
  String? error;
  @override
  void initState() {
    super.initState();
    username.text = widget.saved?['username'] ?? '';
    password.text = widget.saved?['password'] ?? '';
    hasSaved = remember = widget.saved != null;
    widget.saved?.clear();
    if (widget.readFailed) error = 'Gespeicherte Anmeldung konnte nicht gelesen werden.';
  }
  @override
  void dispose() {
    username.clear();password.clear();username.dispose();password.dispose();super.dispose();
  }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('PowerShell verbinden'),
    content: SizedBox(width: 440, child: SingleChildScrollView(child: Form(key: form,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextFormField(controller: username, autocorrect: false, enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Windows-/AD-Administratorkonto', hintText: r'DOMÄNE\Benutzer oder benutzer@domäne'),
          validator: (value) => value == null || value.trim().isEmpty ? 'Benutzer angeben' : null),
        const SizedBox(height: 12),
        TextFormField(controller: password, obscureText: true, autocorrect: false, enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Windows-Kennwort'),
          validator: (value) => value == null || value.isEmpty ? 'Kennwort angeben' : null),
        if (widget.store.supported && widget.deviceId.isNotEmpty)
          CheckboxListTile(contentPadding: EdgeInsets.zero, value: remember,
            title: const Text('Für dieses Gerät speichern'),
            subtitle: const Text('Geschützter Windows-Anmeldespeicher dieses Windows-Benutzers. Der Dialog erscheint weiterhin vor jeder Verbindung.'),
            onChanged: (value) => setState(() => remember = value == true)),
        if (hasSaved) TextButton(onPressed: () async {
          try {
            await widget.store.delete(widget.deviceId);
            if (mounted) setState(() {hasSaved = remember = false;username.clear();password.clear();});
          } catch (_) {if (mounted) setState(() => error = 'Gespeicherte Anmeldung konnte nicht entfernt werden.');}
        }, child: const Text('Gespeicherte Anmeldung entfernen')),
        const SizedBox(height: 12),
        const Text('Das Konto muss auf dem Zielgerät Administrator sein. Nach erfolgreicher Prüfung läuft die Shell als SYSTEM, nicht unter der eingegebenen Benutzeridentität. Zugangsdaten werden nur auf Wunsch und erst nach erfolgreicher Anmeldung gespeichert.'),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!)),
      ])))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
      FilledButton(onPressed: () {
        if (form.currentState!.validate()) Navigator.pop(context, G3PowerShellLogin(username.text.trim(), password.text, remember: remember));
      }, child: const Text('Verbinden')),
    ],
  );
}
