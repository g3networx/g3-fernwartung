import 'dart:convert';
import 'package:http/http.dart' as http;

const g3ClientVersion = String.fromEnvironment('G3_CLIENT_VERSION', defaultValue: '1.5.0-g3.40.1');
bool g3VersionIsValid(String version) =>
    RegExp(r'^\d+\.\d+\.\d+-g3\.\d+(?:\.\d+)?$').hasMatch(version);

bool g3VersionNewer(String candidate, String current) {
  if (!g3VersionIsValid(candidate) || !g3VersionIsValid(current)) return false;
  final a = RegExp(r'\d+').allMatches(candidate).map((m) => int.parse(m.group(0)!)).toList();
  final b = RegExp(r'\d+').allMatches(current).map((m) => int.parse(m.group(0)!)).toList();
  for (var i = 0; i < a.length || i < b.length; i++) {
    final left = i < a.length ? a[i] : 0;
    final right = i < b.length ? b[i] : 0;
    if (left != right) return left > right;
  }
  return false;
}

Future<String?> g3AvailableUpdate({String current = g3ClientVersion, http.Client? client}) async {
  final own = client == null;
  final transport = client ?? http.Client();
  try {
    final request = http.Request('GET', Uri.https('rust.g3nx.net', '/client/update-v2.json'))..followRedirects = false;
    final response = await transport.send(request).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return null;
    final body = await response.stream.bytesToString().timeout(const Duration(seconds: 10));
    final data = jsonDecode(body);
    final version = data is Map ? data['version'] : null;
    return version is String && g3VersionNewer(version, current) ? version : null;
  } catch (_) {
    return null;
  } finally {
    if (own) transport.close();
  }
}

