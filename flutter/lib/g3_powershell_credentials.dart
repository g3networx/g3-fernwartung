import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Current Windows user's vault, scoped to this server and target device.
class G3PowerShellCredentials {
  bool get supported => Platform.isWindows;
  String _target(String id) => 'g3 OpsLinX/PowerShell/rust.g3nx.net/${Uri.encodeComponent(id)}';
  Future<Map<String, String>?> read(String id) async {
    if (!supported || id.isEmpty) return null;
    final name = _target(id).toNativeUtf16();
    final result = calloc<Pointer<CREDENTIAL>>();
    try {
      GetLastError();
      if (CredRead(name, CRED_TYPE.CRED_TYPE_GENERIC, 0, result) == 0) {
        if (GetLastError() == 1168) return null;
        throw StateError('Windows-Anmeldespeicher nicht verfügbar');
      }
      try {
        final entry = result.value.ref;
        if (entry.UserName == nullptr || entry.CredentialBlob == nullptr || entry.CredentialBlobSize == 0) throw StateError('Gespeicherte Anmeldung ist unvollständig');
        return {'username': entry.UserName.toDartString(), 'password': utf8.decode(entry.CredentialBlob.asTypedList(entry.CredentialBlobSize))};
      } finally {
        final entry = result.value.ref;
        if (entry.CredentialBlob != nullptr) entry.CredentialBlob.asTypedList(entry.CredentialBlobSize).fillRange(0, entry.CredentialBlobSize, 0);
        CredFree(result.value);
      }
    } finally {calloc.free(result); calloc.free(name);}
  }
  Future<void> write(String id, String username, String password) async {
    final bytes = utf8.encode(password);
    if (!supported || id.isEmpty || username.isEmpty || bytes.isEmpty || bytes.length > 2560) throw StateError('Windows-Anmeldung kann nicht gespeichert werden');
    final name = _target(id).toNativeUtf16();
    final user = username.toNativeUtf16();
    final blob = calloc<Uint8>(bytes.length);
    final entry = calloc<CREDENTIAL>();
    try {
      blob.asTypedList(bytes.length).setAll(0, bytes);
      entry.ref..Type = CRED_TYPE.CRED_TYPE_GENERIC..TargetName = name..UserName = user
        ..Persist = CRED_PERSIST.CRED_PERSIST_LOCAL_MACHINE..CredentialBlobSize = bytes.length..CredentialBlob = blob;
      if (CredWrite(entry, 0) == 0) throw StateError('Windows-Anmeldung konnte nicht gespeichert werden');
    } finally {
      blob.asTypedList(bytes.length).fillRange(0, bytes.length, 0);bytes.fillRange(0, bytes.length, 0);
      calloc.free(entry);calloc.free(blob);calloc.free(user);calloc.free(name);
    }
  }
  Future<void> delete(String id) async {
    if (!supported || id.isEmpty) return;
    final name = _target(id).toNativeUtf16();
    try {
      GetLastError();
      if (CredDelete(name, CRED_TYPE.CRED_TYPE_GENERIC, 0) == 0 && GetLastError() != 1168) throw StateError('Gespeicherte Anmeldung konnte nicht entfernt werden');
    } finally {calloc.free(name);}
  }
}

Future<bool> saveVerifiedG3PowerShellLogin(Map<String, String> login, {G3PowerShellCredentials? credentials}) async {
  try {
    if (login['save'] == 'Y') {
      if (login['submitted'] != 'Y') return false;
      await (credentials ?? G3PowerShellCredentials()).write(login['deviceId']!, login['username']!, login['password']!);
    }
    return true;
  } catch (_) {return false;}
  finally {login.clear();}
}
