import 'dart:convert';
import 'package:http/http.dart' as http;

const g3ClientVersion = String.fromEnvironment('G3_CLIENT_VERSION', defaultValue: '1.5.0-g3.61.20049');
const g3DisplayVersion = String.fromEnvironment('G3_CLIENT_DISPLAY_VERSION', defaultValue: 'g3.6.1 Build 111126');
String g3VersionLabel(String version) {
  final m = RegExp(r'^1\.5\.0-g3\.(60|61|62)\.(\d+)$').firstMatch(version);
  if (m == null) return version;
  final day = DateTime.utc(2020, 1, 1).add(Duration(days: int.parse(m[2]!) ~/ 8));
  String two(int value) => value.toString().padLeft(2, '0');
  const releases = {'60': 'g3.6', '61': 'g3.6.1', '62': 'g3.6.2'};
  final release = releases[m[1]];
  return '$release Build ${two(day.day)}${two(day.month)}${two(day.year % 100)}';
}
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
    final request = http.Request('GET', Uri.https('linx.g3nx.net', '/client/update-v2.json'))..followRedirects = false;
    final response = await transport.send(request).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return null;
    final body = await response.stream.bytesToString().timeout(const Duration(seconds: 10));
    final data = jsonDecode(body);
    final version = data is Map ? (data['release_version'] ?? data['version']) : null;
    return version is String && g3VersionNewer(version, current) ? version : null;
  } catch (_) {
    return null;
  } finally {
    if (own) transport.close();
  }
}

