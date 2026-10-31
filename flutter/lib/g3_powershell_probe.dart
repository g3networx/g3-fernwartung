import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'g3_addressbook_api.dart';
import 'g3_addressbook_credentials.dart';
import 'generated_bridge.dart';
import 'models/platform_model.dart';

String _failureCategory(String message) {
  final text = message.toLowerCase();
  for (final entry in const {
    'no session with peer id': 'native-session-not-found',
    'offline': 'remote-offline',
    'wrong password': 'native-password-rejected',
    'password': 'login-or-password-required',
    'no active console user': 'no-active-windows-user',
    'key mismatch': 'server-key-mismatch',
    'insecure': 'secure-transport-unavailable',
    'not allowed': 'connection-not-allowed',
    'permission': 'permission-denied',
    'relay': 'relay-connection-failed',
    'rendezvous': 'rendezvous-connection-failed',
    'incoming only': 'incoming-only-client',
    'reset by peer': 'connection-reset',
    'timeout': 'connection-timeout',
    'failed to connect': 'connection-unreachable',
  }.entries) {
    if (text.contains(entry.key)) return entry.value;
  }
  return 'native-error-unclassified';
}

/// A bounded read-only connection diagnostic. Input and credentials use stdin;
/// output contains only the verified remote identity and PowerShell version.
Future<void> runG3PowerShellProbe() async {
  void phase(String name) => stdout.writeln('G3_POWERSHELL_PHASE=$name');
  await Isolate.spawn((_) async {
    await Future<void>.delayed(const Duration(seconds: 120));
    exit(2);
  }, null);
  final proof = <String, dynamic>{
    'actualRemotePowerShellTested': false,
    'ownSessionClosed': false,
    'readOnlyCommands': true,
  };
  final api = G3AddressBookApi();
  final transport = http.Client();
  final session = UuidValue(const Uuid().v4());
  final terminal = 1000000 + Random.secure().nextInt(1000000000);
  final nonce = const Uuid().v4().replaceAll('-', '');
  StreamSubscription<EventToUI>? subscription;
  var added = false, opened = false, requested = false, sent = false;
  var output = '', osUsername = '', osPassword = '';
  final done = Completer<void>();
  final terminalClosed = Completer<void>();
  try {
    final input = jsonDecode(await stdin.transform(utf8.decoder).join()
        .timeout(const Duration(seconds: 15))) as Map<String, dynamic>;
    final device = input['deviceId'];
    final id = input['expectedNativeId'];
    final computer = input['expectedComputer'];
    osUsername = input['osUsername'] as String? ?? '';
    osPassword = input['osPassword'] as String? ?? '';
    input.clear();
    if (device is! int || id is! String || computer is! String ||
        !RegExp(r'^\d{6,12}$').hasMatch(id) ||
        !RegExp(r'^[A-Za-z0-9_-]{1,63}$').hasMatch(computer) ||
        osUsername.isEmpty != osPassword.isEmpty) {
      throw StateError('invalid-input');
    }
    phase('native-initialization');
    await platformFFI.init('main');
    await bind.mainCheckConnectStatus();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!await bind.optionSynced()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('installed-service-authorization-required');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // The native core can reuse a peer's terminal connection. Do not inherit
    // another terminal's account, or close an existing support session.
    if (bind.peerGetSessionsCount(id: id, connType: 5) != 0) {
      throw StateError('existing-terminal-session');
    }
    phase('addressbook-authorization');
    api.token = await G3AddressBookCredentials().read();
    if (api.token == null) throw StateError('addressbook-login-required');
    final tree = await api.request('tree');
    final targets = (tree['devices'] as List).where((d) =>
        d['id'] == device && d['rustdesk_id'] == id);
    if (targets.length != 1) throw StateError('addressbook-identity-mismatch');
    phase('handoff-creation');
    final grant = await api.request('connect', body: {'device_id': device});
    final uri = Uri.parse(grant['uri'] as String);
    if (uri.scheme != 'g3fernwartung' || uri.host != 'g3-session' ||
        !RegExp(r'^/[A-Za-z0-9_-]{54}$').hasMatch(uri.path) ||
        uri.hasQuery || uri.hasFragment) throw StateError('invalid-handoff');
    phase('handoff-redemption');
    final localId = (await bind.mainGetMyId().timeout(const Duration(seconds: 5))).replaceAll(' ', '');
    if (!RegExp(r'^\d{6,12}$').hasMatch(localId)) throw StateError('local-device-id-unavailable');
    proof['localNativeId'] = localId;
    final response = await transport.send(http.Request('GET',
      Uri.https('rust.g3nx.net', '/client-handoff'))
      ..followRedirects = false
      ..headers['X-G3-Client-ID'] = localId
      ..headers['Authorization'] = 'Bearer ${uri.path.substring(1)}')
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw StateError('handoff-denied');
    final credential = jsonDecode(await response.stream.bytesToString().timeout(const Duration(seconds: 15)))
        as Map<String, dynamic>;
    if (credential['id'] != id || credential['password'] is! String) {
      throw StateError('handoff-identity-mismatch');
    }
    bind.mainSetEnv(key: 'IS_TERMINAL_ADMIN', value: osUsername.isEmpty ? null : 'Y');
    phase('native-session-add');
    final error = bind.sessionAddSync(sessionId: session, id: id,
        isFileTransfer: false, isViewCamera: false, isPortForward: false,
        isRdp: false, isTerminal: true, switchUuid: '', forceRelay: true,
        password: credential['password'], isSharedPassword: false);
    credential.clear();
    if (error.isNotEmpty) throw StateError('session-refused');
    added = true;
    phase('native-session-start');
    subscription = bind.sessionStart(sessionId: session, id: id).listen((event) async {
      if (event is! EventToUI_Event) return;
      try {
        final e = jsonDecode(event.field0) as Map<String, dynamic>;
        if (e['name'] == 'terminal_response' && e['type'] == 'closed' &&
            e['terminal_id'].toString() == terminal.toString() &&
            !terminalClosed.isCompleted) terminalClosed.complete();
        if (done.isCompleted) return;
        if (e['name'] == 'msgbox') {
          final type = e['type']?.toString() ?? '';
          if (RegExp(r'^[a-z-]{1,64}$').hasMatch(type)) proof['nativeMessageType'] = type;
          if (osUsername.isNotEmpty && e['type'] == 'terminal-admin-login') {
            final username = osUsername, password = osPassword;
            osUsername = ''; osPassword = '';
            await bind.sessionLogin(sessionId: session, osUsername: username,
                osPassword: password, password: '', remember: false);
            return;
          }
          proof['nativeFailureCategory'] = _failureCategory('${e['title']} ${e['text']}');
          throw StateError('connection-or-login-refused');
        }
        if (e['name'] == 'peer_info' && !requested) {
          phase('remote-peer-accepted');
          requested = true;
          await bind.sessionOpenTerminal(sessionId: session,
              terminalId: terminal, rows: 30, cols: 180);
        }
        if (e['name'] != 'terminal_response' ||
            e['terminal_id'].toString() != terminal.toString()) return;
        if (e['type'] == 'opened' && !sent) {
          if ((e['message'] as String? ?? '').startsWith('Reconnected to existing terminal')) {
            requested = false;
            throw StateError('existing-persistent-terminal');
          }
          if (e['success'] != true && e['success'] != 'true') {
            throw StateError('terminal-refused');
          }
          opened = true; sent = true;
          phase('remote-terminal-opened');
          await bind.sessionSendTerminalInput(sessionId: session, terminalId: terminal,
              data: "Write-Output ('$nonce|' + \$env:COMPUTERNAME + '|' + \$PSVersionTable.PSVersion.ToString() + '|' + (6*7) + '|' + [Security.Principal.WindowsIdentity]::GetCurrent().Name);\r");
        }
        if (e['type'] == 'data') {
          output += utf8.decode(base64Decode(e['data'] as String), allowMalformed: true);
          if (output.length > 262144) throw StateError('output-limit');
          final clean = output.replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '');
          final match = RegExp('$nonce\\|${RegExp.escape(computer)}\\|([0-9.]+)\\|42\\|([^\\r\\n]+)', caseSensitive: false).firstMatch(clean);
          if (match != null) {
            phase('remote-result-verified');
            proof.addAll({'actualRemotePowerShellTested': true,
              'remoteComputer': computer, 'nativeId': id,
              'powerShellVersion': match.group(1),
              'windowsIdentity': match.group(2)!.trim(), 'calculationResult': 42});
            done.complete();
          }
        }
        if (e['type'] == 'error' || e['type'] == 'closed') {
          throw StateError('terminal-ended-before-proof');
        }
      } catch (_) {
        if (!done.isCompleted) done.completeError(StateError('remote-probe-failed'));
      }
    }, onError: (Object error) {
      proof['nativeStreamErrorType'] = error.runtimeType.toString();
      proof['nativeFailureCategory'] = _failureCategory(error.toString());
      if (!done.isCompleted) done.completeError(StateError('native-stream-failed'));
    });
    await done.future.timeout(const Duration(seconds: 60));
  } catch (error) {
    proof['status'] = error is StateError ? error.message : 'probe-failed';
  } finally {
    osUsername = ''; osPassword = ''; output = '';
    if (added) {
      phase('own-terminal-close');
      try {
        if (requested) {
          await bind.sessionCloseTerminal(sessionId: session, terminalId: terminal);
          if (opened) await terminalClosed.future.timeout(const Duration(seconds: 5));
        }
        proof['ownTerminalClosed'] = !opened || terminalClosed.isCompleted;
      } catch (_) { proof['ownSessionClosed'] = false; }
      stdout.writeln('G3_POWERSHELL_RESULT=${jsonEncode(proof)}');
      phase('own-session-close');
      try {
        await bind.sessionClose(sessionId: session).timeout(const Duration(seconds: 5));
        proof['ownSessionClosed'] = proof['ownTerminalClosed'] == true;
      } catch (_) { proof['ownSessionClosed'] = false; }
    }
    await subscription?.cancel();
    api.close(); transport.close();
    proof['finishedAt'] = DateTime.now().toUtc().toIso8601String();
    stdout.writeln('G3_POWERSHELL_PROBE=${jsonEncode(proof)}');
  }
  exit(proof['actualRemotePowerShellTested'] == true && proof['ownSessionClosed'] == true ? 0 : 1);
}
