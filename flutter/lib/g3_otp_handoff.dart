import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

typedef _CallNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _Call = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _Free = void Function(Pointer<Utf8>);
typedef _CancelNative = Void Function();
typedef _Cancel = void Function();

/// The private ephemeral key stays in the installed native core, never in JSON.
class G3OtpHandoff {
  final DynamicLibrary _library;
  G3OtpHandoff()
      : _library = DynamicLibrary.open(
            '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}librustdesk.dll');

  Map<String, dynamic> _call(String name, Map<String, dynamic> request) {
    final input = jsonEncode(request).toNativeUtf8();
    Pointer<Utf8> output = nullptr;
    try {
      output = _library.lookupFunction<_CallNative, _Call>(name)(input);
      if (output == nullptr) throw StateError('otp-handoff-unavailable');
      final result = jsonDecode(output.toDartString()) as Map<String, dynamic>;
      if (result['ok'] != true) throw StateError('otp-handoff-not-verified');
      return result;
    } finally {
      calloc.free(input);
      if (output != nullptr) {
        _library.lookupFunction<_FreeNative, _Free>('g3_otp_probe_free')(output);
      }
    }
  }

  Map<String, dynamic> begin(String nativeId, String nonce) => _call(
      'g3_otp_probe_begin', {'expectedNativeId': nativeId, 'nonce': nonce});

  String open(Map<String, dynamic> envelope) {
    final result = _call('g3_otp_probe_open', envelope);
    final password = result['password'];
    result.clear();
    if (password is! String || password.isEmpty || password.length > 128) {
      throw StateError('otp-handoff-not-verified');
    }
    return password;
  }

  void cancel() =>
      _library.lookupFunction<_CancelNative, _Cancel>('g3_otp_probe_cancel')();
}
