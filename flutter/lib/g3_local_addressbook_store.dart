import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'g3_local_addressbook_crypto.dart';

class G3LocalEntry {
  final String id, name, group, notes, passwordProtected, book;
  G3LocalEntry(
      {required this.id,
      required this.name,
      this.group = '',
      this.notes = '',
      this.book = '',
      this.passwordProtected = ''}) {
    if (!RegExp(r'^[A-Za-z0-9_-]{6,40}$').hasMatch(id) ||
        !G3LocalAddressBookStore.validBook(book) ||
        name.trim().isEmpty ||
        name.length > 160 ||
        group.length > 160 ||
        notes.length > 2000 ||
        passwordProtected.length > 24000 ||
        (passwordProtected.isNotEmpty &&
            !passwordProtected.startsWith(G3LocalPasswordCipher.prefix))) {
      throw const FormatException('Ungültiger Adressbucheintrag.');
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'group': group,
        'notes': notes,
        if (book.isNotEmpty) 'book': book,
        if (passwordProtected.isNotEmpty) 'passwordProtected': passwordProtected
      };

  G3LocalEntry withPassword(String protected) => G3LocalEntry(
      id: id,
      name: name,
      group: group,
      notes: notes,
      book: book,
      passwordProtected: protected);

  factory G3LocalEntry.fromJson(dynamic value) {
    if (value is! Map<String, dynamic> ||
        value.keys.any((k) => ![
              'id',
              'name',
              'group',
              'notes',
              'book',
              'passwordProtected'
            ].contains(k)) ||
        value['id'] is! String ||
        value['name'] is! String ||
        (value.containsKey('book') && value['book'] is! String) ||
        (value.containsKey('group') && value['group'] is! String) ||
        (value.containsKey('notes') && value['notes'] is! String) ||
        (value.containsKey('passwordProtected') &&
            value['passwordProtected'] is! String)) {
      throw const FormatException('Ungültiger Adressbucheintrag.');
    }
    return G3LocalEntry(
        id: value['id'],
        name: value['name'],
        group: value['group'] ?? '',
        notes: value['notes'] ?? '',
        book: value['book'] ?? '',
        passwordProtected: value['passwordProtected'] ?? '');
  }
}

class G3LocalAddressBookStore {
  static const maxBytes = 2 * 1024 * 1024;
  static const maxEntries = 5000;
  final File file;
  final _passwordCipher = G3LocalPasswordCipher();
  G3LocalAddressBookStore(this.file);

  static bool validBook(String path) =>
      path.isEmpty ||
      (path.length <= 512 &&
          path.split('/').length <= 8 &&
          path.split('/').every((part) =>
              part.trim() == part &&
              part.isNotEmpty &&
              part.length <= 80 &&
              part != '.' &&
              part != '..' &&
              !RegExp(r'[\x00-\x1f\\]').hasMatch(part)));

  static List<String> bookPaths(Iterable<String> paths) {
    final result = <String>{};
    for (final path in paths) {
      if (!validBook(path)) {
        throw const FormatException('Ungültiger lokaler Adressbuchpfad.');
      }
      final parts = path.split('/');
      for (var i = 1; path.isNotEmpty && i <= parts.length; i++) {
        result.add(parts.take(i).join('/'));
      }
    }
    if (result.length > 500) {
      throw const FormatException('Maximal 500 lokale Adressbücher möglich.');
    }
    return result.toList()..sort();
  }

  static List<String> decodeBooks(String text) {
    final entries = decode(text);
    final data =
        jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
    return bookPaths([
      ...((data['books'] as List?) ?? []).cast<String>(),
      ...entries.map((e) => e.book),
    ]);
  }

  Future<List<String>> readBooks() async => await file.exists()
      ? decodeBooks(await file.readAsString())
      : bookPaths((await read()).map((e) => e.book));

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
        ![1, 2, 3].contains(data['version']) ||
        data['entries'] is! List ||
        data.keys.any(
            (k) => !['format', 'version', 'entries', 'books'].contains(k)) ||
        (data.containsKey('books') &&
            (data['version'] != 3 ||
                data['books'] is! List ||
                (data['books'] as List).any((b) => b is! String))) ||
        (data['entries'] as List).length > maxEntries) {
      throw const FormatException(
          'Keine unterstützte lokale g3-Adressbuchdatei.');
    }
    final entries =
        (data['entries'] as List).map(G3LocalEntry.fromJson).toList();
    bookPaths([
      ...((data['books'] as List?) ?? []).cast<String>(),
      ...entries.map((e) => e.book),
    ]);
    if (data['version'] == 1 &&
        entries.any((e) => e.passwordProtected.isNotEmpty)) {
      throw const FormatException(
          'Ungültige Adressbuchversion für gespeicherte Kennwörter.');
    }
    if (entries.map((e) => e.id).toSet().length != entries.length) {
      throw const FormatException('Die Datei enthält doppelte Geräte-IDs.');
    }
    return entries;
  }

  static String encode(List<G3LocalEntry> entries,
      {List<String> books = const []}) {
    final paths = bookPaths([...books, ...entries.map((e) => e.book)]);
    final text = const JsonEncoder.withIndent('  ').convert({
      'format': 'g3-local-addressbook',
      'version': paths.isEmpty ? 2 : 3,
      if (paths.isNotEmpty) 'books': paths,
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

  Future<T> _change<T>(FutureOr<T> Function(List<G3LocalEntry>) change,
      {void Function(List<String>)? changeBooks}) async {
    await file.parent.create(recursive: true);
    final lock = await File('${file.path}.lock').open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
      final entries = await read();
      final books = await readBooks();
      final result = await change(entries);
      changeBooks?.call(books);
      final text = encode(entries, books: books);
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

  Future<void> put(G3LocalEntry entry,
          {String? previousId,
          String? password,
          bool removePassword = false}) =>
      _change((entries) {
        if (entries.any((e) => e.id == entry.id && e.id != previousId)) {
          throw const FormatException('Diese Geräte-ID ist bereits vorhanden.');
        }
        final index = entries.indexWhere((e) => e.id == previousId);
        if (previousId != null && index < 0) {
          throw const FormatException(
              'Der Eintrag wurde inzwischen entfernt. Bitte neu laden.');
        }
        final previous = index < 0 ? null : entries[index];
        var protected = previous?.passwordProtected ?? entry.passwordProtected;
        if (removePassword) {
          protected = '';
        } else if (password != null && password.isNotEmpty) {
          protected = _passwordCipher.protect(password, entry.id);
        } else if (previous != null &&
            previous.id != entry.id &&
            protected.isNotEmpty) {
          protected = _passwordCipher.protect(
              _passwordCipher.unprotect(protected, previous.id), entry.id);
        }
        final saved = entry.withPassword(protected);
        if (index < 0) {
          entries.add(saved);
        } else {
          entries[index] = saved;
        }
      });

  Future<String> passwordFor(G3LocalEntry entry) async =>
      _passwordCipher.unprotect(entry.passwordProtected, entry.id);

  Future<String> encryptedExport(String password) async {
    final entries = await read();
    final books = await readBooks();
    final payload = jsonEncode({
      'format': 'g3-local-addressbook-transfer',
      'version': books.isEmpty ? 1 : 2,
      if (books.isNotEmpty) 'books': books,
      'entries': [
        for (final e in entries)
          {
            'id': e.id,
            'name': e.name,
            'group': e.group,
            'notes': e.notes,
            if (e.book.isNotEmpty) 'book': e.book,
            'password': await passwordFor(e),
          }
      ]
    });
    return G3LocalBookExportCipher.encrypt(payload, password);
  }

  Future<List<G3LocalEntry>> openEncryptedExport(
          String text, String password) async =>
      (await openEncryptedBook(text, password)).entries;

  Future<G3LocalBookImport> openEncryptedBook(
      String text, String password) async {
    final clear = await G3LocalBookExportCipher.decrypt(text, password);
    final data = jsonDecode(clear);
    if (data is! Map<String, dynamic> ||
        data['format'] != 'g3-local-addressbook-transfer' ||
        ![1, 2].contains(data['version']) ||
        data['entries'] is! List ||
        data.keys.any(
            (k) => !['format', 'version', 'entries', 'books'].contains(k)) ||
        (data.containsKey('books') &&
            (data['version'] != 2 ||
                data['books'] is! List ||
                (data['books'] as List).any((b) => b is! String))) ||
        (data['entries'] as List).length > maxEntries) {
      throw const FormatException('Ungültiger Inhalt der Exportdatei.');
    }
    final entries = <G3LocalEntry>[];
    for (final value in data['entries'] as List) {
      if (value is! Map<String, dynamic> ||
          value['password'] is! String ||
          value.containsKey('passwordProtected')) {
        throw const FormatException('Ungültiger Eintrag in der Exportdatei.');
      }
      final metadata = Map<String, dynamic>.from(value)..remove('password');
      final entry = G3LocalEntry.fromJson(metadata);
      entries.add(entry
          .withPassword(_passwordCipher.protect(value['password'], entry.id)));
    }
    final books = bookPaths([
      ...((data['books'] as List?) ?? []).cast<String>(),
      ...entries.map((e) => e.book),
    ]);
    encode(entries, books: books);
    return G3LocalBookImport(entries, books);
  }

  Future<void> remove(String id) => _change((entries) {
        entries.removeWhere((e) => e.id == id);
      });

  Future<void> addBook(String path) => _change((entries) {
        if (path.isEmpty || !validBook(path)) {
          throw const FormatException(
              'Bitte einen gültigen Adressbuchnamen eingeben.');
        }
      }, changeBooks: (books) {
        if (books.contains(path)) {
          throw const FormatException(
              'Dieses lokale Adressbuch ist bereits vorhanden.');
        }
        books.add(path);
      });

  Future<void> removeBook(String path) => _change((entries) {
        if (path.isEmpty ||
            entries.any((e) => e.book == path || e.book.startsWith('$path/'))) {
          throw const FormatException(
              'Nur leere lokale Adressbücher können gelöscht werden.');
        }
      }, changeBooks: (books) {
        if (books.any((b) => b.startsWith('$path/'))) {
          throw const FormatException(
              'Bitte zuerst die Unteradressbücher entfernen.');
        }
        books.remove(path);
      });

  Future<int> importEntries(List<G3LocalEntry> imported,
          {List<String> books = const []}) =>
      _change((entries) {
        final ids = entries.map((e) => e.id).toSet();
        var added = 0;
        for (final entry in imported) {
          if (ids.add(entry.id)) {
            entries.add(entry);
            added++;
          }
        }
        return added;
      }, changeBooks: (existing) => existing.addAll(books));
}

class G3LocalBookImport {
  final List<G3LocalEntry> entries;
  final List<String> books;
  G3LocalBookImport(this.entries, this.books);
}
