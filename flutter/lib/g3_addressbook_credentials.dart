import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Windows stores only the revocable native session, in the current user's vault.
class G3AddressBookCredentials {
  final String target;
  G3AddressBookCredentials(
      {this.target = 'g3 OpsLinX/AddressBook/rust.g3nx.net/v1'});
  bool get supported => Platform.isWindows;

  Future<String?> read() async {
    if (!supported) return null;
    final name = target.toNativeUtf16();
    final result = calloc<Pointer<CREDENTIAL>>();
    try {
      // Resolve the lazy GetLastError binding before CredRead sets its error.
      GetLastError();
      if (CredRead(name, CRED_TYPE.CRED_TYPE_GENERIC, 0, result) == 0) {
        if (GetLastError() == 1168) return null;
        throw Exception('Windows-Anmeldespeicher konnte nicht gelesen werden');
      }
      try {
        final credential = result.value.ref;
        final token = utf8.decode(credential.CredentialBlob.asTypedList(
            credential.CredentialBlobSize));
        return RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token) ? token : null;
      } finally {
        CredFree(result.value);
      }
    } finally {
      calloc.free(result);
      calloc.free(name);
    }
  }

  Future<void> write(String token) async {
    if (!supported || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      throw Exception('Gespeicherte Anmeldung ist hier nicht verfügbar');
    }
    final name = target.toNativeUtf16();
    final user = 'g3-Adressbuch'.toNativeUtf16();
    final blob = calloc<Uint8>(token.length);
    final credential = calloc<CREDENTIAL>();
    try {
      blob.asTypedList(token.length).setAll(0, utf8.encode(token));
      credential.ref
        ..Type = CRED_TYPE.CRED_TYPE_GENERIC
        ..TargetName = name
        ..UserName = user
        ..Persist = CRED_PERSIST.CRED_PERSIST_LOCAL_MACHINE
        ..CredentialBlobSize = token.length
        ..CredentialBlob = blob;
      if (CredWrite(credential, 0) == 0) {
        throw Exception('Windows konnte die Anmeldung nicht speichern');
      }
    } finally {
      blob.asTypedList(token.length).fillRange(0, token.length, 0);
      calloc.free(credential);
      calloc.free(blob);
      calloc.free(user);
      calloc.free(name);
    }
  }

  Future<void> delete() async {
    if (!supported) return;
    final name = target.toNativeUtf16();
    try {
      GetLastError();
      if (CredDelete(name, CRED_TYPE.CRED_TYPE_GENERIC, 0) == 0 &&
          GetLastError() != 1168) {
        throw Exception('Gespeicherte Anmeldung konnte nicht entfernt werden');
      }
    } finally {
      calloc.free(name);
    }
  }
}
