import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_hbb/g3_update_check.dart';
void main() {
 test('start check reports a newer release and never installs', () async {
  var requests = 0;
  final client = MockClient((request) async {
   requests++;
   expect(request.url.toString(), 'https://rust.g3nx.net/client/update-v2.json');
   expect(request.method, 'GET');
   return http.Response('{"version":"1.5.0-g3.25"}', 200);
  });
  expect(await g3AvailableUpdate(current:'1.5.0-g3.24',client:client), '1.5.0-g3.25');
  expect(requests,1);
 });
 test('current, older and malformed versions do not offer an update', () {
  expect(g3VersionNewer('1.5.0-g3.24','1.5.0-g3.24'),false);
  expect(g3VersionNewer('1.5.0-g3.23','1.5.0-g3.24'),false);
  expect(g3VersionNewer('1.5.0-g3.25-evil','1.5.0-g3.24'),false);
 });
 test('unavailable or invalid feed leaves client startup usable', () async {
  expect(await g3AvailableUpdate(client:MockClient((_) async => http.Response('offline',503))),isNull);
  expect(await g3AvailableUpdate(client:MockClient((_) async => http.Response('not json',200))),isNull);
 });
}
