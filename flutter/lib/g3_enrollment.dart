import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_hbb/models/platform_model.dart';

bool g3IsAdhoc() => bind.mainGetAppNameSync() == 'g3Soforthilfe';
Future<void> applyG3Provisioning(String body) async {
  final data = jsonDecode(body) as Map<String, dynamic>;
  final additionalPasswords = data['additional_passwords'];
  final servicePassword = data['service_password'];
  if (additionalPasswords is List && additionalPasswords.isNotEmpty) {
    await bind.mainSetOption(key: 'g3-service-password-provision', value: jsonEncode(additionalPasswords));
  } else if (servicePassword is String && servicePassword.isNotEmpty) {
    await bind.mainSetOption(key: 'g3-service-password-provision', value: jsonEncode([servicePassword]));
  }
  final activity = data['activity_token'];
  if (activity is String && activity.isNotEmpty) {
    await bind.mainSetOption(key: 'g3-activity-token', value: activity);
  }
  final password = data['permanent_password'];
  if (password is! String || password.isEmpty) return;
  bool applied = false;
  for (var attempt = 0; attempt < 5; attempt++) {
    applied = await bind.mainSetPermanentPasswordWithResult(password: password);
    if (applied) break;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  if (!applied) throw Exception('Password setup failed');
  await bind.mainSetOption(
      key: 'verification-method', value: bind.mainGetAppNameSync() == 'g3Host' ? 'use-both-passwords' : 'use-permanent-password');
  await bind.mainSetOption(key: 'approve-mode', value: 'password');
  final r = await http
      .post(Uri.https('rust.g3nx.net', '/client-provisioning/confirm'),
          headers: {
            'Authorization': 'Bearer ${data['provisioning_token']}',
            'Content-Type': 'application/json'
          },
          body: jsonEncode({'device_id': data['device_id']}))
      .timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) throw Exception('Password acknowledgment failed');
}

String g3CustomerCode() {
  final filename = '${bind.mainGetEnv(key: 'RUSTDESK_APPNAME')}|${bind.mainGetEnv(key: 'G3_MSI_SOURCE')}';
  return RegExp(r'kunde_([A-Za-z0-9_-]{32})(?:-host)?-install', caseSensitive: false)
          .firstMatch(filename)
          ?.group(1) ??
      bind.mainGetLocalOption(key:'g3-pending-customer-code');
}

Future<void> g3PrepareEnrollmentAfterInstall() async {
  final token=g3CustomerCode();
  if(token.isNotEmpty) await bind.mainSetLocalOption(key:'g3-pending-customer-code',value:token);
  await bind.mainSetLocalOption(key:'g3-install-enrollment-pending',value:'Y');
}

Future<void> showG3Enrollment(BuildContext context,
    {bool setup = false, bool forceCode = false}) async {
  if (setup && bind.mainGetLocalOption(key: 'g3-enrolled') != 'Y') await g3BootstrapReporting();
  if (setup && bind.mainGetLocalOption(key: 'g3-enrolled') == 'Y') return;
  if (!context.mounted) return;
  final token = forceCode ? '' : g3CustomerCode();
  await showDialog<void>(
      context: context,
      builder: (_) => token.isEmpty
          ? G3EnrollmentDialog(setup: setup)
          : G3CustomerEnrollment(token: token));
}

class G3EnrollmentDialog extends StatefulWidget {
  final bool setup;
  const G3EnrollmentDialog({super.key, this.setup = false});
  @override
  State<G3EnrollmentDialog> createState() => _G3EnrollmentState();
}

class _G3EnrollmentState extends State<G3EnrollmentDialog> {
  final code = TextEditingController();
  final name = TextEditingController(text: Platform.localHostname);
  @override
  void initState() {
    super.initState();
    code.text = bind.mainGetLocalOption(key: 'g3-pending-enrollment');
    final savedName = bind.mainGetLocalOption(key: 'g3-pending-name');
    if (savedName.isNotEmpty) name.text = savedName;
  }

  String? path;
  String? error;
  bool busy = false;
  bool done = false;
  @override
  void dispose() {
    code.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final token = code.text.trim();
    if (!RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(token)) {
      setState(
          () => error = 'Bitte den vollständigen Einrichtungscode eingeben.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final client = http.Client();
    try {
      final uri = Uri.https('rust.g3nx.net', '/client-enrollment');
      final target = await client.get(uri, headers: {
        'Authorization': 'Bearer $token'
      }).timeout(const Duration(seconds: 15));
      if (target.statusCode != 200)
        throw Exception('Code ungültig oder abgelaufen');
      final destination =
          (jsonDecode(target.body) as Map<String, dynamic>)['path'] as String;
      final id = (await bind.mainGetMyId()).replaceAll(' ', '');
      if (!RegExp(r'^[A-Za-z0-9_-]{6,40}$').hasMatch(id))
        throw Exception('ID not ready');
      final response = await client
          .post(uri,
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json'
              },
              body: jsonEncode(
                  {'id': id, 'name': name.text.trim(), 'provisioning': 2}))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 201) {
        if (mounted)
          setState(() => error = response.statusCode == 409
              ? 'Dieses Gerät ist bereits zugeordnet.'
              : 'Zuordnung fehlgeschlagen. Bitte erneut versuchen.');
        return;
      }
      await applyG3Provisioning(response.body);
      await bind.mainSetLocalOption(key: 'g3-enrolled', value: 'Y');
      await bind.mainSetLocalOption(key:'g3-pending-customer-code',value:'');
      await bind.mainSetLocalOption(key:'g3-install-enrollment-pending',value:'');
      await bind.mainSetLocalOption(key: 'g3-pending-enrollment', value: '');
      await bind.mainSetLocalOption(key: 'g3-pending-name', value: '');
      if (mounted)
        setState(() {
          path = destination;
          done = true;
        });
    } catch (_) {
      if (mounted)
        setState(() => error =
            'Zuordnung nicht möglich. Bitte Verbindung prüfen und erneut versuchen.');
    } finally {
      client.close();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Gerät zuordnen'),
          content: SizedBox(
              width: 430,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (done)
                      Text('Das Gerät wurde dem Adressbuch $path zugeordnet.')
                    else ...[
                      if (path == null)
                        const Text(
                            'Den Einrichtungscode erhältst du von deinem Techniker. Das Gerät erscheint im gewählten Adressbuch. Hinterlegte Passwortvorgaben werden übernommen.'),
                      if (path == null)
                        TextField(
                            controller: code,
                            decoration: const InputDecoration(
                                labelText: 'Einrichtungscode'),
                            autocorrect: false,
                            enableSuggestions: false),
                      if (path != null) ...[
                        const Text('Zieladressbuch'),
                        Text(path!,
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        TextField(
                            controller: name,
                            maxLength: 200,
                            decoration:
                                const InputDecoration(labelText: 'Gerätename'))
                      ],
                      if (error != null)
                        Text(error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                    ]
                  ])),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.of(context).pop(),
                child: Text(done ? 'Schließen' : 'Später')),
            if (!done)
              FilledButton(
                  onPressed: busy ? null : submit,
                  child: Text(busy
                      ? 'Bitte warten …'
                      : path == null
                          ? 'Gerät zuordnen'
                          : 'Gerät zuordnen'))
          ]);
}

class G3CustomerEnrollment extends StatefulWidget {
  final String token;
  const G3CustomerEnrollment({super.key, required this.token});
  @override
  State<G3CustomerEnrollment> createState() => _G3CustomerEnrollmentState();
}

class _G3CustomerEnrollmentState extends State<G3CustomerEnrollment> {
  List<dynamic> books = [];
  int? selected;
  String? error;
  bool busy = true;
  bool done = false;
  final name = TextEditingController(text: Platform.localHostname);
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final r = await http.get(
          Uri.https('rust.g3nx.net', '/client-customer-enrollment'),
          headers: {
            'Authorization': 'Bearer ${widget.token}'
          }).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw Exception();
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      if (mounted)
        setState(() {
          books = data['books'] as List<dynamic>;
          selected = data['root'] as int;
          busy = false;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          error =
              'Zuordnungscode konnte nicht geladen werden. Bitte erneut laden oder einen anderen Code verwenden.';
          busy = false;
        });
    }
  }

  Future<void> register() async {
    bool registered=false;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final id = (await bind.mainGetMyId()).replaceAll(' ', '');
      if (!RegExp(r'^[A-Za-z0-9_-]{6,40}$').hasMatch(id)) {
        if (mounted) setState(() => error = 'Der Fernwartungsdienst liefert noch keine Geräte-ID. Bitte den Dienststatus prüfen lassen.');
        return;
      }
      final r = await http
          .post(Uri.https('rust.g3nx.net', '/client-customer-enrollment'),
              headers: {
                'Authorization': 'Bearer ${widget.token}',
                'Content-Type': 'application/json'
              },
              body: jsonEncode({
                'id': id,
                'name': name.text.trim(),
                'customer_id': selected,
                'provisioning': 2
              }))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 201) {
        if (mounted) setState(() => error = r.statusCode == 409
            ? 'Diese Geräte-ID ist bereits zugeordnet. Bitte einen Techniker kontaktieren.'
            : 'Zuordnung fehlgeschlagen. Bitte Verbindung und Zuordnungscode prüfen.');
        return;
      }
      registered=true;
      await applyG3Provisioning(r.body);
      await bind.mainSetLocalOption(key: 'g3-enrolled', value: 'Y');
      await bind.mainSetLocalOption(key:'g3-pending-customer-code',value:'');
      await bind.mainSetLocalOption(key:'g3-install-enrollment-pending',value:'');
      if (mounted) setState(() => done = true);
    } catch (_) {
      if (mounted)
        setState(() => error =
            registered ? 'Das Gerät ist zugeordnet. Die Passwortvorgabe konnte noch nicht übernommen werden. Bitte den installierten Client öffnen und erneut versuchen.' : 'Zuordnung nicht möglich. Bitte Verbindung prüfen und erneut versuchen.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Gerät zuordnen'),
          content: SizedBox(
              width: 430,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (done)
                      const Text(
                          'Das Gerät wurde dem gewählten Adressbuch zugeordnet.')
                    else ...[
                      if (books.isNotEmpty)
                        DropdownButtonFormField<int>(
                            value: selected,
                            isExpanded: true,
                            decoration: const InputDecoration(
                                labelText: 'Adressbuch / Unteradressbuch'),
                            items: books
                                .map((b) => DropdownMenuItem<int>(
                                    value: b['id'] as int,
                                    child: Text(b['path'] as String,
                                        overflow: TextOverflow.ellipsis)))
                                .toList(),
                            onChanged: busy
                                ? null
                                : (v) => setState(() => selected = v)),
                      if (books.isNotEmpty)
                        TextField(
                            controller: name,
                            maxLength: 200,
                            decoration:
                                const InputDecoration(labelText: 'Gerätename')),
                      if (busy) const Text('Bitte warten …'),
                      if (error != null)
                        Text(error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error))
                    ]
                  ])),
          actions: [
            if(error!=null && !busy && books.isEmpty) TextButton(onPressed:load,child:const Text('Erneut laden')),
            if(error!=null && !busy) TextButton(onPressed:() { Navigator.of(context).pop(); showG3Enrollment(context,forceCode:true); },child:const Text('Anderen Code verwenden')),
            TextButton(
                onPressed: busy ? null : () => Navigator.of(context).pop(),
                child: Text(done ? 'Schließen' : 'Später')),
            if (!done && books.isNotEmpty)
              FilledButton(
                  onPressed: busy ? null : register,
                  child: const Text('Gerät zuordnen'))
          ]);
}

Future<void> g3BootstrapReporting()async{
 try{

  String id='';
  for(var i=0;i<20;i++){id=(await bind.mainGetMyId()).replaceAll(' ','');if(RegExp(r'^[A-Za-z0-9_-]{6,40}$').hasMatch(id))break;await Future<void>.delayed(const Duration(seconds:1));}
  if(!RegExp(r'^[A-Za-z0-9_-]{6,40}$').hasMatch(id))return;
  http.Response? response;
  for(var attempt=0;attempt<(g3IsAdhoc()?7:1);attempt++){response=await http.get(Uri.https('rust.g3nx.net','/client-bootstrap',{'id':id,'adhoc':g3IsAdhoc()?'1':'0'})).timeout(const Duration(seconds:15));if(response.statusCode==200)break;await Future<void>.delayed(const Duration(seconds:10));}
  if(response==null || response.statusCode!=200)return;
  final nonce=(jsonDecode(response.body) as Map<String,dynamic>)['challenge'] as String;
  final signature=bind.mainGetOptionSync(key:'g3-bootstrap-sign:g3-bootstrap-v1:$id:$nonce');
  if(signature.isEmpty)return;
  final r=await http.post(Uri.https('rust.g3nx.net','/client-bootstrap'),headers:{'Content-Type':'application/json'},body:jsonEncode({'id':id,'challenge':nonce,'signature':signature,'adhoc':g3IsAdhoc(),'name':Platform.localHostname})).timeout(const Duration(seconds:15));
  if(r.statusCode==200){
    final data=jsonDecode(r.body) as Map<String,dynamic>;
    await applyG3Provisioning(r.body);
    if(data['registered']==true){
      await bind.mainSetLocalOption(key:'g3-enrolled',value:'Y');
      await bind.mainSetLocalOption(key:'g3-pending-enrollment',value:'');
      await bind.mainSetLocalOption(key:'g3-pending-name',value:'');
    }
    await bind.mainSetLocalOption(key:'g3-pending-customer-code',value:'');
    await bind.mainSetLocalOption(key:'g3-install-enrollment-pending',value:'');
  }
 }catch(_){}
}
