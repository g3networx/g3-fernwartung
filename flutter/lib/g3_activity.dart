import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:flutter_hbb/models/platform_model.dart';

final _g3Ledger = _G3Ledger();

void g3RecoverLegacyJournal() {
  void flush() { if (bind.mainGetLocalOption(key: 'g3-activity-journal').isNotEmpty) _g3Ledger.sync(const []); }
  flush();
  Timer.periodic(const Duration(seconds: 30), (_) => flush());
}

bool get g3AccountingBusy => _g3Ledger.busy;
Future<void> g3FlushConnections(List<Map<String,dynamic>> connections) async {
  while (_g3Ledger.busy) { await Future<void>.delayed(const Duration(milliseconds:20)); }
  _g3Ledger.lastAttempt=0;
  await _g3Ledger.sync(const []);
}
void g3RecordConnections(List<Map<String, dynamic>> connections) {
  // Accounting is owned by the native connection lifecycle.
  _g3Ledger.sync(const []);
}

class _G3Ledger {
  bool busy = false, loaded = false;
  int lastAttempt = 0;
  final Map<String, Map<String, dynamic>> records = {};
  final Map<int, String> active = {};
  final Map<String, Stopwatch> clocks = {};
  Future<void> save() async {
    await bind.mainSetLocalOption(
        key: 'g3-activity-journal', value: jsonEncode(records));
  }

  Future<void> sync(List<Map<String, dynamic>> connections) async {
    if (busy) return;
    busy = true;
    try {
      final key = bind.mainGetOptionSync(key: 'g3-activity-token');

      if (!loaded) {
        loaded = true;
        try {
          final saved =
              jsonDecode(bind.mainGetLocalOption(key: 'g3-activity-journal'))
                  as Map<String, dynamic>;
          for (final e in saved.entries) {
            final r = Map<String, dynamic>.from(e.value);
            if (r['closed'] != true) r['interrupted'] = true;
            r['closed'] = true;
            r['sequence'] = (r['sequence'] as int) + 1;
            r['_pending'] = true;
            records[e.key] = r;
          }
        } catch (_) {}
      }
      final before = jsonEncode(records);
      final live = <int>{};
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      for (final c in connections) {
        if (c['authorized'] != true || c['disconnected'] == true) continue;
        final id = c['id'] as int;
        live.add(id);
        if (!active.containsKey(id)) {
          final event = base64UrlEncode(
                  List<int>.generate(24, (_) => Random.secure().nextInt(256)))
              .replaceAll('=', '');
          active[id] = event;
          clocks[event] = Stopwatch()..start();
          records[event] = {
            'event': event,
            'sequence': 0,
            'started': now,
            'elapsed': 0,
            'closed': false,
            'peer_id': c['peer_id'],
            'kind': c['kind'],
            '_sent': 0,
            '_pending': true
          };
        }
        final event = active[id]!;
        final r = records[event]!;
        if (now - (r['_sent'] as int) >= 30) {
          r['elapsed'] = clocks[event]!.elapsed.inSeconds;
          r['sequence'] = (r['sequence'] as int) + 1;
          r['_sent'] = now;
          r['_pending'] = true;
        }
      }
      for (final id in active.keys.toList()) {
        if (live.contains(id)) continue;
        final event = active.remove(id)!;
        final r = records[event]!;
        r['elapsed'] = clocks.remove(event)!.elapsed.inSeconds;
        r['sequence'] = (r['sequence'] as int) + 1;
        r['closed'] = true;
        r['_pending'] = true;
      }
      if (jsonEncode(records) != before) await save();
      if(key.isEmpty)return;
      if (!records.values.any((r) => r['_pending'] == true) ||
          now - lastAttempt < 5) return;
      lastAttempt = now;
      for (final event in records.keys.toList()) {
        final r = records[event]!;
        if (r['_pending'] != true) continue;
        final payload = Map<String, dynamic>.from(r)
          ..removeWhere((k, v) => k.startsWith('_'));
        try {
          final response = await http
              .post(Uri.https('rust.g3nx.net', '/client-activity'),
                  headers: {
                    'Authorization': 'Bearer $key',
                    'Content-Type': 'application/json'
                  },
                  body: jsonEncode(payload))
              .timeout(const Duration(seconds: 10));
          if (response.statusCode == 200) {
            if (r['closed'] == true) {
              records.remove(event);
            } else {
              r['_pending'] = false;
            }
          }
        } catch (_) {}
      }
      await save();
    } finally {
      busy = false;
    }
  }
}
