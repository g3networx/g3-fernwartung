List<String>? g3HandoffArguments(Uri uri) {
  if (uri.scheme != 'g3fernwartung' || uri.authority != 'g3-session' ||
      uri.pathSegments.length != 1 || uri.hasQuery || uri.hasFragment) return null;
  final token = uri.pathSegments.single;
  return RegExp(r'^[A-Za-z0-9_-]{54}$').hasMatch(token) ? ['--g3-session', token] : null;
}
