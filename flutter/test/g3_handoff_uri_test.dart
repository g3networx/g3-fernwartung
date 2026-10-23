import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/g3_handoff_uri.dart';
void main() {
 test('cold and warm URI parsing produces the same handled command without redeeming', () {
  final token = List.filled(54, 'A').join();
  final uri = Uri.parse('g3fernwartung://g3-session/$token');
  expect(g3HandoffArguments(uri), ['--g3-session',token]);
  expect(g3HandoffArguments(uri), ['--g3-session',token]);
 });
 test('malformed or unrelated URI is not a handoff command', () {
  expect(g3HandoffArguments(Uri.parse('g3fernwartung://g3-session/short')),isNull);
  expect(g3HandoffArguments(Uri.parse('https://g3-session/short')),isNull);
  expect(g3HandoffArguments(Uri.parse('g3fernwartung://123456789')),isNull);
 });
}
