import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/g3_update_check.dart';
void main() {
 test('new visible format hides internal same-day upgrade counter', () {
  expect(g3VersionLabel('1.5.0-g3.60.19984'), 'g3.6 Build 031126');
  expect(g3VersionLabel('1.5.0-g3.60.19985'), 'g3.6 Build 031126');
  expect(g3VersionNewer('1.5.0-g3.60.19985','1.5.0-g3.60.19984'),isTrue);
  expect(g3VersionNewer('1.5.0-g3.60.19985','1.5.0-g3.50.2'),isTrue);
 });
 test('build date advances and legacy versions retain their label', () {
  expect(g3VersionLabel('1.5.0-g3.60.19992'), 'g3.6 Build 041126');
  expect(g3VersionLabel('1.5.0-g3.50.2'),'1.5.0-g3.50.2');
 });
}
