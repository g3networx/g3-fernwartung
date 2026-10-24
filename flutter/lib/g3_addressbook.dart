import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'g3_addressbook_api.dart';
import 'g3_addressbook_credentials.dart';

class G3AddressBook extends StatefulWidget {
  final Future<void> Function(String uri) onConnect;
  final G3AddressBookApi? api;
  final G3AddressBookCredentials? credentials;
  const G3AddressBook(
      {super.key, required this.onConnect, this.api, this.credentials});
  @override
  State<G3AddressBook> createState() => _G3AddressBookState();
}

class _G3AddressBookState extends State<G3AddressBook> {
  late final api = widget.api ?? G3AddressBookApi();
  late final credentials = widget.credentials ?? G3AddressBookCredentials();
  final search = TextEditingController();
  final expanded = <int>{};
  List<Map<String, dynamic>> books = [], devices = [];
  Map<String, dynamic>? selected;
  String? username, error, displayCode;
  bool busy = false, remember = true, loading = false;
  int generation = 0;
  Timer? refresh;

  @override
  void initState() {
    super.initState();
    restore();
    refresh = Timer.periodic(const Duration(seconds: 30), (_) {
      if (api.token != null && !busy) load();
    });
  }

  Future<void> restore() async {
    try {
      api.token = await credentials.read();
      if (api.token != null) await load();
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'Gespeicherte Anmeldung konnte nicht geladen werden. Bitte erneut anmelden.');
      }
    }
  }

  @override
  void dispose() {
    generation++;
    refresh?.cancel();
    api.close();
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (loading) return;
    loading = true;
    final current = generation;
    try {
      final data = await api.request('tree');
      if (!mounted || current != generation) return;
      setState(() {
        username = data['username'] as String;
        books = (data['books'] as List).cast<Map<String, dynamic>>();
        devices = (data['devices'] as List).cast<Map<String, dynamic>>();
        final matches = devices.where((d) => d['id'] == selected?['id']);
        selected = matches.isEmpty ? null : matches.first;
        error = null;
      });
    } on G3AddressBookExpired {
      if (mounted && current == generation) {
        api.token = null;
        if (mounted) {
          setState(() {
            username = null;
            books = [];
            devices = [];
            selected = null;
            error =
                'Die g3-Anmeldung ist abgelaufen oder wurde widerrufen. Bitte erneut anmelden.';
          });
        }
        try {
          await credentials.delete();
        } catch (_) {
          if (mounted) {
            setState(() => error =
                'Die g3-Anmeldung ist ungültig. Der Windows-Anmeldespeicher konnte nicht geleert werden. Bitte erneut anmelden.');
          }
        }
      }
    } catch (_) {
      if (mounted && current == generation) {
        setState(() {
          books = [];
          devices = [];
          selected = null;
          error = 'Adressbuch nicht erreichbar. Bitte erneut laden.';
        });
      }
    } finally {
      loading = false;
    }
  }

  Future<void> login() async {
    final current = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final verifier = G3AddressBookApi.verifier();
      final start = await api.start(verifier);
      final uri = Uri.parse(start['verification_uri'] as String);
      if (uri.scheme != 'https' ||
          uri.host != 'rust.g3nx.net' ||
          uri.path != '/client-addressbook/authorize') throw Exception();
      if (!mounted || current != generation) return;
      setState(() => displayCode = start['display_code'] as String);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw Exception();
      }
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      while (mounted &&
          current == generation &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 4));
        if (!mounted || current != generation) return;
        final result = await api.request('login/poll',
            body: {'device_code': start['device_code'], 'verifier': verifier});
        if (result['pending'] == true) continue;
        final token = result['token'];
        if (token is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
          throw Exception();
        }
        if (!mounted || current != generation) return;
        api.token = token;
        if (remember && credentials.supported) {
          try {
            await credentials.write(token);
          } catch (_) {
            await api.request('logout', body: {});
            api.token = null;
            throw Exception();
          }
        }
        await load();
        return;
      }
      throw Exception();
    } catch (_) {
      if (mounted && current == generation) {
        setState(() => error =
            'Anmeldung nicht abgeschlossen. Bitte g3-Login und Bestätigungscode prüfen und erneut versuchen.');
      }
    } finally {
      if (mounted && current == generation) {
        setState(() {
          busy = false;
          displayCode = null;
        });
      }
    }
  }

  Future<void> logout() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await api.request('logout', body: {});
    } on G3AddressBookExpired {
      // An expired grant can still be removed from the local vault.
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error =
              'Abmelden nicht möglich. Bitte Verbindung prüfen und erneut versuchen.';
        });
      }
      return;
    }
    try {
      await credentials.delete();
      generation++;
      api.token = null;
      if (mounted) {
        setState(() {
          username = null;
          selected = null;
          books = [];
          devices = [];
          expanded.clear();
          search.clear();
          busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error =
              'Anmeldung serverseitig beendet. Windows-Anmeldespeicher konnte nicht geleert werden.';
        });
      }
    }
  }

  Future<void> open(Map<String, dynamic> device) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data =
          await api.request('connect', body: {'device_id': device['id']});
      final uri = Uri.parse(data['uri'] as String);
      if (uri.scheme != 'g3fernwartung' || uri.hasQuery || uri.hasFragment) {
        throw Exception();
      }
      await widget.onConnect(uri.toString());
    } on G3AddressBookExpired {
      await load();
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'Verbindung konnte nicht freigegeben werden. Bitte Rechte und Erreichbarkeit prüfen.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  bool matches(Map<String, dynamic> d, String query) =>
      '${d['name']} ${d['rustdesk_id']}'.toLowerCase().contains(query);

  List<Widget> tree(int? parent, String query,
      [int depth = 0, Set<int> ancestors = const {}]) {
    final rows = <Widget>[];
    for (final book in books.where((b) => b['parent_id'] == parent)) {
      final id = book['id'] as int;
      if (ancestors.contains(id)) continue;
      final children = tree(id, query, depth + 1, {...ancestors, id});
      final peers = devices
          .where((d) =>
              d['customer_id'] == id &&
              (query.isEmpty ||
                  matches(d, query) ||
                  (book['path'] as String).toLowerCase().contains(query)))
          .toList();
      if (query.isNotEmpty &&
          peers.isEmpty &&
          children.isEmpty &&
          !(book['path'] as String).toLowerCase().contains(query)) continue;
      final isOpen = query.isNotEmpty || expanded.contains(id);
      rows.add(ListTile(
        dense: true,
        contentPadding: EdgeInsets.only(
            left: 8 + (depth.clamp(0, 8) * 14).toDouble(), right: 4),
        leading: Icon(isOpen ? Icons.folder_open : Icons.folder_outlined),
        title: Text(book['name'] as String, overflow: TextOverflow.ellipsis),
        trailing: Icon(isOpen ? Icons.expand_more : Icons.chevron_right),
        onTap: () => setState(() {
          if (!expanded.add(id)) expanded.remove(id);
        }),
      ));
      if (isOpen) {
        for (final d in peers) {
          rows.add(Padding(
            padding:
                EdgeInsets.only(left: 14 + (depth.clamp(0, 8) * 14).toDouble()),
            child: InkWell(
              onDoubleTap: busy ? null : () => open(d),
              child: ListTile(
                dense: true,
                selected: selected?['id'] == d['id'],
                leading: statusIcon(d),
                title:
                    Text(d['name'] as String, overflow: TextOverflow.ellipsis),
                subtitle: Text(d['rustdesk_id'] as String),
                onTap: () => setState(() => selected = d),
              ),
            ),
          ));
        }
        rows.addAll(children);
      }
    }
    return rows;
  }

  String status(Map<String, dynamic> d) =>
      {'online': 'Online', 'offline': 'Offline'}[d['presence']] ??
      'Status unbekannt';
  Widget statusIcon(Map<String, dynamic> d) => Tooltip(
        message: status(d),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.circle,
              size: 9,
              color: d['presence'] == 'online'
                  ? Colors.green
                  : d['presence'] == 'offline'
                      ? Colors.red
                      : Colors.grey),
          const SizedBox(width: 6),
          const Icon(Icons.computer, size: 21),
        ]),
      );

  Widget details() {
    final d = selected;
    if (d == null) {
      return const Center(
          child: Text('Gerät im Adressbuch auswählen',
              textAlign: TextAlign.center));
    }
    final book = books.where((b) => b['id'] == d['customer_id']).first;
    return SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(children: [
          const Icon(Icons.computer, size: 48),
          const SizedBox(height: 12),
          Text(d['name'] as String,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(status(d)),
          SelectableText('Geräte-ID: ${d['rustdesk_id']}'),
          const SizedBox(height: 8),
          Text(book['path'] as String, textAlign: TextAlign.center),
          const SizedBox(height: 18),
          FilledButton.icon(
              onPressed: busy ? null : () => open(d),
              icon: const Icon(Icons.desktop_windows),
              label: const Text('Verbinden')),
        ]));
  }

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('g3-Adressbuch',
                        style: Theme.of(context).textTheme.titleMedium),
                    if (username != null) Text(username!),
                    if (username != null)
                      TextButton(
                          onPressed: busy ? null : logout,
                          child: const Text('Abmelden')),
                    if (api.token != null)
                      IconButton(
                          tooltip: 'Adressbuch neu laden',
                          onPressed: busy ? null : load,
                          icon: const Icon(Icons.refresh)),
                  ]),
              if (error != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              if (username == null && api.token == null) ...[
                const Text(
                    'Mit deinem g3-Konto anmelden. Es gelten dieselben Adressbuchrechte wie in der WebGUI.'),
                CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(credentials.supported
                        ? 'Angemeldet bleiben'
                        : 'Anmeldung nur für diese Sitzung'),
                    value: remember && credentials.supported,
                    onChanged: busy || !credentials.supported
                        ? null
                        : (value) => setState(() => remember = value ?? false)),
                if (displayCode != null)
                  Text('Im Browser bestätigen – Code: $displayCode',
                      style: Theme.of(context).textTheme.titleMedium),
                Wrap(spacing: 8, children: [
                  FilledButton(
                      onPressed: busy ? null : login,
                      child: Text(busy
                          ? 'Warte auf g3-Anmeldung …'
                          : 'Mit g3 anmelden')),
                  if (busy)
                    TextButton(
                        onPressed: () {
                          generation++;
                          setState(() {
                            busy = false;
                            displayCode = null;
                          });
                        },
                        child: const Text('Abbrechen')),
                ]),
              ],
              if (username != null) ...[
                TextField(
                    controller: search,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Geräte, IDs und Adressbücher suchen')),
                const SizedBox(height: 8),
                Expanded(child: LayoutBuilder(builder: (context, constraints) {
                  final rows = tree(null, search.text.trim().toLowerCase());
                  final list = rows.isEmpty
                      ? const Center(
                          child: Text('Keine freigegebenen Geräte gefunden.'))
                      : ListView(children: rows);
                  if (constraints.maxWidth < 650) {
                    return Column(children: [
                      Expanded(child: list),
                      const Divider(height: 1),
                      SizedBox(
                          height: constraints.maxHeight * .38, child: details())
                    ]);
                  }
                  return Row(children: [
                    Expanded(child: list),
                    const VerticalDivider(width: 18),
                    Expanded(child: details())
                  ]);
                })),
              ] else
                const Spacer(),
            ])),
      );
}
