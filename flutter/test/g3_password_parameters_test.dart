import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/g3_password_parameters.dart';
void main() {
 test('Web credentials are only parameters and legacy defaults remain supplementary', () {
  expect(g3ProvisioningPasswordParameters({'additional_passwords':['standard-fixture','own-fixture'],'service_password':'standard-fixture','permanent_password':'legacy-fixture'}),['standard-fixture','own-fixture','legacy-fixture']);
  expect(g3ProvisioningPasswordParameters({}),isEmpty);
 });
 test('malformed or excessive parameters are rejected without guessing', () {
  expect(()=>g3ProvisioningPasswordParameters({'additional_passwords':['valid-fixture',7]}),throwsStateError);
  expect(()=>g3ProvisioningPasswordParameters({'additional_passwords':'invalid'}),throwsStateError);
  expect(()=>g3ProvisioningPasswordParameters({'additional_passwords':List.generate(17,(i)=>'fixture-$i')}),throwsStateError);
 });
 test('a displayed label alone never confirms a password write', () {
  expect(g3PasswordActionConfirmed('rejected','add','label',['label']),isFalse);
  expect(g3PasswordActionConfirmed('confirmed','add','label',[]),isFalse);
  expect(g3PasswordActionConfirmed('confirmed','add','label',['label']),isTrue);
  expect(g3PasswordActionConfirmed('confirmed','remove','label',[]),isTrue);
 });
}
