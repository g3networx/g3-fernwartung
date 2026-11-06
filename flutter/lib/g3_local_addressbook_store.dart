import 'dart:convert';
import 'dart:io';

class G3LocalEntry {
  final String id, name, group, notes;
  G3LocalEntry(
      {required this.id,
      required this.name,
      this.group = '',
      this.notes = ''}) {
    if (!RegExp(r'^[A-Za-z0-9_-]{6,40}$').hasMatch(id) ||
        name.trim().isEmpty ||
        name.length > 160 ||
        group.length > 160 ||
        notes.length > 2000) {
      throw const FormatException('Ungültiger Adressbucheintrag.');
    }
  }

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'group': group, 'notes': notes};

  factory G3LocalEntry.fromJson(dynamic value) {
    if (value is! Map<String, dynamic> ||
        value.keys.any((k) => !['id', 'name', 'group', 'notes'].contains(k)) ||
        value['id'] is! String ||
        value['name'] is! String ||
        (value.containsKey('group') && value['group'] is! String) ||
        (value.containsKey('notes') && value['notes'] is! String)) {
      throw const FormatException('Ungültiger Adressbucheintrag.');
    }
    return G3LocalEntry(
        id: value['id'],
        name: value['name'],
        group: value['group'] ?? '',
        notes: value['notes'] ?? '');
  }
}

class G3LocalAddressBookStore {
  static const maxBytes = 2 * 1024 * 1024;
  static const maxEntries = 5000;
  final File file;
  G3LocalAddressBookStore(this.file);

  factory G3LocalAddressBookStore.forCurrentPc() {
    final root = Platform.environment['LOCALAPPDATA'];
    if (!Platform.isWindows || root == null || root.isEmpty) {
      throw StateError(
          'Das lokale Adressbuch benötigt einen lokalen Windows-Datenspeicher.');
    }
    return G3LocalAddressBookStore(
        File('$root/g3NetworX/Fernwartung/local-addressbook-v1.json'));
  }

  static List<G3LocalEntry> decode(String text) {
    if (utf8.encode(text).length > maxBytes) {
      throw const FormatException(
          'Die Adressbuchdatei ist zu groß (maximal 2 MB).');
    }
    final data =
        jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
    if (data is! Map<String, dynamic> ||
        data['format'] != 'g3-local-addressbook' ||
        data['version'] != 1 ||
        data['entries'] is! List ||
        data.keys.any((k) => !['format', 'version', 'entries'].contains(k)) ||
        (data['entries'] as List).length > maxEntries) {
      throw const FormatException(
          'Keine unterstützte lokale g3-Adressbuchdatei.');
    }
    final entries =
        (data['entries'] as List).map(G3LocalEntry.fromJson).toList();
    if (entries.map((e) => e.id).toSet().length != entries.length) {
      throw const FormatException('Die Datei enthält doppelte Geräte-IDs.');
    }
    return entries;
  }

  static String encode(List<G3LocalEntry> entries) {
    final text = const JsonEncoder.withIndent('  ').convert({
      'format': 'g3-local-addressbook',
      'version': 1,
      'entries': entries.map((e) => e.toJson()).toList(),
    });
    decode(text);
    return text;
  }

  Future<List<G3LocalEntry>> read() async {
    if (!await file.exists()) return [];
    if (await file.length() > maxBytes) {
      throw const FormatException('Die Adressbuchdatei ist zu groß.');
    }
    return decode(await file.readAsString());
  }

  Future<T> _change<T>(T Function(List<G3LocalEntry>) change) async {
    await file.parent.create(recursive: true);
    final lock = await File('${file.path}.lock').open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
      final entries = await read();
      final result = change(entries);
      final text = encode(entries);
      final pending = File(
          '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp');
      try {
        await pending.writeAsString(text, flush: true);
        await pending.rename(file.path);
      } finally {
        if (await pending.exists()) await pending.delete();
      }
      return result;
    } finally {
      await lock.close();
    }
  }

  Future<void> put(G3LocalEntry entry, {String? previousId}) =>
      _change((entries) {
        if (entries.any((e) => e.id == entry.id && e.id != previousId)) {
          throw const FormatException('Diese Geräte-ID ist bereits vorhanden.');
        }
        final index = entries.indexWhere((e) => e.id == previousId);
        if (previousId != null && index < 0) {
          throw const FormatException(
              'Der Eintrag wurde inzwischen entfernt. Bitte neu laden.');
        }
        if (index < 0) {
          entries.add(entry);
        } else {
          entries[index] = entry;
        }
      });

  Future<void> remove(String id) => _change((entries) {
        entries.removeWhere((e) => e.id == id);
      });

  Future<int> importEntries(List<G3LocalEntry> imported) => _change((entries) {
        final ids = entries.map((e) => e.id).toSet();
        var added = 0;
        for (final entry in imported) {
          if (ids.add(entry.id)) {
            entries.add(entry);
            added++;
          }
        }
        return added;
      });
}
