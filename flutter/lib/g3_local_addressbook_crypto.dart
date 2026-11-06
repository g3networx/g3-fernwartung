import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

class G3LocalPasswordCipher {
  static const prefix = 'dpapi-user-v1:';

  String protect(String password, String id) {
    if (password.isEmpty) return '';
    if (password.length > 1024 || utf8.encode(password).length > 4096) {
      throw const FormatException('Das Verbindungskennwort ist zu lang.');
    }
    final bytes = Uint8List.fromList(utf8.encode(password));
    try {
      return prefix + base64Encode(_transform(bytes, id, false));
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  String unprotect(String protected, String id) {
    if (protected.isEmpty) return '';
    if (!protected.startsWith(prefix) || protected.length > 24000) {
      throw const FormatException('Unbekannter lokaler Kennwortschutz.');
    }
    final clear =
        _transform(base64Decode(protected.substring(prefix.length)), id, true);
    try {
      return utf8.decode(clear);
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
  }

  Uint8List _transform(List<int> bytes, String id, bool decrypt) {
    if (!Platform.isWindows) {
      throw StateError('Windows-Kennwortschutz ist hier nicht verfügbar.');
    }
    final input = calloc<CRYPT_INTEGER_BLOB>();
    final entropy = calloc<CRYPT_INTEGER_BLOB>();
    final output = calloc<CRYPT_INTEGER_BLOB>();
    final buffer = calloc<Uint8>(bytes.length);
    final binding = utf8.encode('g3-local-addressbook/password/v1\u0000$id');
    final entropyBuffer = calloc<Uint8>(binding.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      entropyBuffer.asTypedList(binding.length).setAll(0, binding);
      input.ref
        ..cbData = bytes.length
        ..pbData = buffer;
      entropy.ref
        ..cbData = binding.length
        ..pbData = entropyBuffer;
      // Current-user scope; UI forbidden. Never use LOCAL_MACHINE here.
      final ok = decrypt
          ? CryptUnprotectData(
              input, nullptr, entropy, nullptr, nullptr, 1, output)
          : CryptProtectData(
              input, nullptr, entropy, nullptr, nullptr, 1, output);
      if (ok == 0 || output.ref.cbData > 16384) {
        throw StateError(
            'Das Kennwort konnte für diesen Windows-Benutzer nicht entschlüsselt oder geschützt werden.');
      }
      return Uint8List.fromList(
          output.ref.pbData.asTypedList(output.ref.cbData));
    } finally {
      buffer.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      calloc.free(buffer);
      calloc.free(entropyBuffer);
      if (output.ref.pbData != nullptr) {
        output.ref.pbData
            .asTypedList(output.ref.cbData)
            .fillRange(0, output.ref.cbData, 0);
        LocalFree(output.ref.pbData.cast());
      }
      calloc.free(input);
      calloc.free(entropy);
      calloc.free(output);
    }
  }
}

class G3LocalBookExportCipher {
  static const format = 'g3-local-addressbook-encrypted';
  static const iterations = 600000;
  static const maxPayloadBytes = 2 * 1024 * 1024;
  static const maxFileBytes = 4 * 1024 * 1024;
  static final _aad =
      utf8.encode('$format/v1/pbkdf2-hmac-sha256/$iterations/aes-256-gcm');

  static Future<String> encrypt(String payload, String password) =>
      Isolate.run(() async {
        if (password.length < 12 || password.length > 1024) {
          throw const FormatException(
              'Das Exportkennwort muss 12 bis 1024 Zeichen lang sein.');
        }
        final clear = Uint8List.fromList(utf8.encode(payload));
        if (clear.length > maxPayloadBytes) {
          throw const FormatException('Das Adressbuch ist zu groß.');
        }
        final random = Random.secure();
        final salt = List<int>.generate(16, (_) => random.nextInt(256));
        final key = await _key(password, salt);
        try {
          final cipher = AesGcm.with256bits();
          final box = await cipher.encrypt(clear, secretKey: key, aad: _aad);
          return jsonEncode({
            'format': format,
            'version': 1,
            'kdf': 'pbkdf2-hmac-sha256',
            'iterations': iterations,
            'cipher': 'aes-256-gcm',
            'salt': base64Encode(salt),
            'nonce': base64Encode(box.nonce),
            'ciphertext': base64Encode(box.cipherText),
            'tag': base64Encode(box.mac.bytes)
          });
        } finally {
          clear.fillRange(0, clear.length, 0);
          key.destroy();
        }
      });

  static Future<String> decrypt(String text, String password) =>
      Isolate.run(() async {
        if (utf8.encode(text).length > maxFileBytes ||
            password.isEmpty ||
            password.length > 1024) {
          throw const FormatException(
              'Ungültige Exportdatei oder ungültiges Kennwort.');
        }
        try {
          final data = jsonDecode(text);
          const fields = [
            'format',
            'version',
            'kdf',
            'iterations',
            'cipher',
            'salt',
            'nonce',
            'ciphertext',
            'tag'
          ];
          if (data is! Map<String, dynamic> ||
              data.length != fields.length ||
              data.keys.any((k) => !fields.contains(k)) ||
              data['format'] != format ||
              data['version'] != 1 ||
              data['kdf'] != 'pbkdf2-hmac-sha256' ||
              data['iterations'] != iterations ||
              data['cipher'] != 'aes-256-gcm' ||
              ['salt', 'nonce', 'ciphertext', 'tag']
                  .any((k) => data[k] is! String)) {
            throw const FormatException();
          }
          final salt = base64Decode(data['salt']);
          final nonce = base64Decode(data['nonce']);
          final ciphertext = base64Decode(data['ciphertext']);
          final tag = base64Decode(data['tag']);
          if (salt.length != 16 ||
              nonce.length != 12 ||
              tag.length != 16 ||
              ciphertext.length > maxPayloadBytes) {
            throw const FormatException();
          }
          final key = await _key(password, salt);
          try {
            final clear = await AesGcm.with256bits().decrypt(
                SecretBox(ciphertext, nonce: nonce, mac: Mac(tag)),
                secretKey: key,
                aad: _aad);
            try {
              return utf8.decode(clear);
            } finally {
              clear.fillRange(0, clear.length, 0);
            }
          } finally {
            key.destroy();
          }
        } catch (_) {
          throw const FormatException(
              'Die Exportdatei konnte nicht geöffnet werden: Kennwort falsch oder Datei beschädigt.');
        }
      });

  static Future<SecretKey> _key(String password, List<int> salt) async {
    final bytes = Uint8List.fromList(utf8.encode(password));
    final input = SecretKey(bytes);
    try {
      return await Pbkdf2(
              macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
          .deriveKey(secretKey: input, nonce: salt);
    } finally {
      input.destroy();
      bytes.fillRange(0, bytes.length, 0);
    }
  }
}
