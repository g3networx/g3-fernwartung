import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';

class G3Passwords extends StatefulWidget {
  final bool enabled;
  const G3Passwords({super.key, required this.enabled});
  @override
  State<G3Passwords> createState() => _G3PasswordsState();
}
class _G3PasswordsState extends State<G3Passwords> {
  final label = TextEditingController();
  final password = TextEditingController();
  List<String> labels = [];
  bool busy = false;
  String? error;
  @override
  void initState() { super.initState(); refresh(); }
  void refresh() {
    try { labels = (jsonDecode(bind.mainGetOptionSync(key: 'g3-local-password-labels')) as List).cast<String>(); }
    catch (_) { labels = []; }
  }
  @override
  void dispose() { label.dispose(); password.dispose(); super.dispose(); }
  Future<void> change(String action, String name) async {
    if (!widget.enabled || busy) return;
    if (action == 'add' && (name.isEmpty || labels.contains(name) || password.text.length < 8 || password.text.length > 128)) {
      setState(() => error = 'Eindeutige Bezeichnung und Passwort mit 8 bis 128 Zeichen eingeben.'); return;
    }
    setState(() { busy = true; error = null; });
    try {
      await bind.mainSetOption(key: 'g3-local-password-action', value: jsonEncode({'action': action, 'label': name, if (action == 'add') 'password': password.text}));
      await Future<void>.delayed(const Duration(milliseconds: 350));
      refresh();
      final success = action == 'add' ? labels.contains(name) : !labels.contains(name);
      if (!success) { error = 'Speichern nicht bestätigt. Bitte Sicherheitseinstellungen entsperren und erneut versuchen.'; }
      else { label.clear(); password.clear(); }
    } catch (_) { error = 'Speichern nicht möglich.'; }
    if (mounted) setState(() => busy = false);
  }
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Eigene Zugänge für Ihre Administratoren. Bestehendes Gerätepasswort bleibt erhalten.'),
      const SizedBox(height: 12),
      for (final name in labels) Row(children: [
        const Icon(Icons.key, size: 18), const SizedBox(width: 10), Expanded(child: Text(name)),
        IconButton(tooltip: 'Passwort entfernen', onPressed: widget.enabled && !busy ? () => change('remove', name) : null, icon: const Icon(Icons.delete_outline)),
      ]),
      if (labels.isEmpty) const Text('Keine zusätzlichen Kundenpasswörter eingerichtet.'),
      const SizedBox(height: 12),
      TextField(controller: label, enabled: widget.enabled && !busy && labels.length < 16, maxLength: 60, decoration: const InputDecoration(labelText: 'Bezeichnung', hintText: 'z. B. Kunden-Administrator')),
      const SizedBox(height: 8),
      TextField(controller: password, enabled: widget.enabled && !busy && labels.length < 16, obscureText: true, enableSuggestions: false, autocorrect: false, maxLength: 128, decoration: const InputDecoration(labelText: 'Zusätzliches Passwort')),
      if (error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      FilledButton.icon(onPressed: widget.enabled && !busy && labels.length < 16 ? () => change('add', label.text.trim()) : null, icon: const Icon(Icons.add), label: Text(busy ? 'Wird gespeichert …' : 'Passwort hinzufügen')),
    ]),
  );
}
