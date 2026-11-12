import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'g3_addressbook_api.dart';
import 'g3_addressbook_credentials.dart';
import 'g3_otp_handoff.dart';
import 'generated_bridge.dart';
import 'models/platform_model.dart';

/// Native challenge/response only: no desktop, directory listing, file IO,
/// terminal, OS logon, password retry, saved peer password or interactive UI.
Future<void> runG3PasswordProbe() async {
  await Isolate.spawn((_) async {
    await Future<void>.delayed(const Duration(seconds: 90)); exit(2);
  }, null);
  final proof=<String,dynamic>{'actualNativePasswordLoginAccepted':false,
    'ownSessionClosed':false,'remoteFileOperations':false,'desktopOpened':false};
  final api=G3AddressBookApi(); final transport=http.Client();
  final session=UuidValue(const Uuid().v4()); final done=Completer<void>();
  StreamSubscription<EventToUI>? subscription;
  var added=false, password='';
  final elapsed=Stopwatch()..start();
  G3OtpHandoff? otpHandoff;
  final inputLines=StreamIterator<String>(stdin.transform(utf8.decoder).transform(const LineSplitter()));
  try {
    if(!await inputLines.moveNext().timeout(const Duration(seconds:15))) throw StateError('invalid-input');
    final input=jsonDecode(inputLines.current) as Map<String,dynamic>;
    final row=input['deviceId'], id=input['expectedNativeId'], kind=input['credentialKind'];
    final sealedOtp=input['sealedOtpHandoff']==true;
    password=input['password'] as String? ?? ''; input.clear();
    if(row is! int || id is! String || !RegExp(r'^\d{6,12}$').hasMatch(id) ||
       !const ['book','standard','otp'].contains(kind) ||
       (sealedOtp && (kind!='otp' || password.isNotEmpty))) throw StateError('invalid-input');
    proof.addAll({'deviceId':row,'nativeId':id,'credentialKind':kind});
    await platformFFI.init('main'); await bind.mainCheckConnectStatus();
    final deadline=DateTime.now().add(const Duration(seconds:10));
    while(!await bind.optionSynced()) {
      if(DateTime.now().isAfter(deadline)) throw StateError('installed-service-authorization-required');
      await Future<void>.delayed(const Duration(milliseconds:100));
    }
    if(bind.peerGetSessionsCount(id:id,connType:1)!=0) throw StateError('existing-file-session-deferred');
    api.token=await G3AddressBookCredentials().read();
    if(api.token==null) throw StateError('normal-addressbook-login-required');
    final tree=await api.request('tree');
    if((tree['devices'] as List).where((d)=>d['id']==row && d['rustdesk_id']==id).length!=1)
      throw StateError('addressbook-identity-mismatch');
    if(sealedOtp) {
      otpHandoff=G3OtpHandoff();
      final nonce=const Uuid().v4().replaceAll('-', '');
      final request=otpHandoff.begin(id,nonce);
      stdout.writeln('G3_OTP_REQUEST=${jsonEncode(request)}');
      await stdout.flush();
      if(!await inputLines.moveNext().timeout(const Duration(seconds:25))) throw StateError('otp-handoff-unavailable');
      final envelope=jsonDecode(inputLines.current) as Map<String,dynamic>;
      password=otpHandoff.open(envelope);envelope.clear();
      proof['currentOtpSealedHandoffVerified']=true;
    }
    if(kind=='book') {
      final grant=await api.request('connect',body:{'device_id':row});
      final uri=Uri.parse(grant['uri'] as String);
      if(uri.scheme!='g3fernwartung' || uri.host!='g3-session' ||
         !RegExp(r'^/[A-Za-z0-9_-]{54}$').hasMatch(uri.path) || uri.hasQuery || uri.hasFragment)
        throw StateError('invalid-handoff');
      final response=await transport.send(http.Request('GET',Uri.https('linx.g3nx.net','/client-handoff'))
        ..followRedirects=false ..headers['Authorization']='Bearer ${uri.path.substring(1)}')
        .timeout(const Duration(seconds:15));
      if(response.statusCode!=200) throw StateError('handoff-denied');
      final credential=jsonDecode(await response.stream.bytesToString()) as Map<String,dynamic>;
      if(credential['id']!=id || credential['password'] is! String) throw StateError('handoff-identity-mismatch');
      password=credential['password'];credential.clear();
    }
    if(password.isEmpty || password.runes.length>128) throw StateError('password-unavailable');
    if(sealedOtp && elapsed.elapsed>=const Duration(seconds:80)) throw StateError('otp-handoff-unavailable');
    final error=bind.sessionAddSync(sessionId:session,id:id,isFileTransfer:true,
      isViewCamera:false,isPortForward:false,isRdp:false,isTerminal:false,
      switchUuid:'',forceRelay:true,password:password,isSharedPassword:false,loginMethod:'');
    password='';
    if(error.isNotEmpty) throw StateError('session-refused');
    added=true;
    subscription=bind.sessionStart(sessionId:session,id:id).listen((event) {
      if(event is! EventToUI_Event || done.isCompleted) return;
      try {
        final e=jsonDecode(event.field0) as Map<String,dynamic>;
        if(e['name']=='peer_info') {
          proof['actualNativePasswordLoginAccepted']=true;done.complete();
        } else if(e['name']=='msgbox') {
          done.completeError(StateError('native-password-login-rejected'));
        }
      } catch(_) { if(!done.isCompleted) done.completeError(StateError('native-event-failed')); }
    },onError:(Object _) { if(!done.isCompleted) done.completeError(StateError('native-stream-failed')); });
    final remaining=const Duration(seconds:80)-elapsed.elapsed;
    final authTimeout=sealedOtp && remaining<const Duration(seconds:40) ? remaining : const Duration(seconds:40);
    await done.future.timeout(authTimeout);
    proof['status']='native-password-accepted';
  } catch(error) {
    proof['status']=error is StateError ? error.message : 'native-password-not-verified';
  } finally {
    password='';
    if(added) {
      try { await bind.sessionClose(sessionId:session).timeout(const Duration(seconds:5));
        proof['ownSessionClosed']=true;
      } catch(_) { proof['ownSessionClosed']=false; }
    }
    try { otpHandoff?.cancel(); }
    catch(_) { proof['otpKeyCleanupVerified']=false; }
    try { await inputLines.cancel(); }
    catch(_) { proof['inputClosedVerified']=false; }
    await subscription?.cancel();api.close();transport.close();
    stdout.writeln('G3_PASSWORD_PROBE=${jsonEncode(proof)}');
  }
  exit(proof['actualNativePasswordLoginAccepted']==true && proof['ownSessionClosed']==true ? 0 : 1);
}
