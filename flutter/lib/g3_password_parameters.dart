List<String> g3ProvisioningPasswordParameters(Map<String,dynamic> data) {
  final result=<String>[];
  final additional=data['additional_passwords'];
  if(additional!=null && additional is! List) throw StateError('Invalid password parameters');
  final values=<dynamic>[if(additional is List) ...additional,
    data['service_password'],data['permanent_password']];
  for(final value in values) {
    if(value==null || value=='') continue;
    if(value is! String || value.runes.length>128) throw StateError('Invalid password parameter');
    if(!result.contains(value)) result.add(value);
  }
  if(result.length>16) throw StateError('Too many password parameters');
  return result;
}
bool g3PasswordActionConfirmed(String receipt,String action,String label,List<String> labels) {
  return receipt=='confirmed' && (action=='add' ? labels.contains(label) : action=='remove' && !labels.contains(label));
}
