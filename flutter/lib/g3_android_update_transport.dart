import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'g3_update_check.dart';
import 'g3_update_metadata.dart';

const g3AndroidUpdateHosts = [
  'linx.g3nx.net',
  'rust.g3nx.net',
  'opslinx02.g3nx.net',
  'opslinx03.g3nx.net',
];

Future<T> g3AndroidUpdateRequest<T>(
  String path,
  Future<T> Function(http.StreamedResponse response) read, {
  List<String> hosts = g3AndroidUpdateHosts,
  http.Client Function() createClient = http.Client.new,
}) async {
  Object? lastError;
  for (final host in hosts) {
    final client = createClient();
    final request = http.Request('GET', Uri.https(host, path))
      ..followRedirects = false;
    try {
      final response =
          await client.send(request).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        throw http.ClientException('HTTP ${response.statusCode}', request.url);
      }
      return await read(response);
    } on TimeoutException catch (error) {
      lastError = error;
    } on http.ClientException catch (error) {
      lastError = error;
    } on IOException catch (error) {
      lastError = error;
    } on FormatException catch (error) {
      lastError = error;
    } finally {
      client.close();
    }
  }
  throw http.ClientException('Android update unavailable ($lastError)');
}

typedef G3AndroidUpdate = ({String version, String digest, int size});

Future<G3AndroidUpdate?> g3AvailableAndroidUpdate({
  String current = g3ClientVersion,
  List<String> hosts = g3AndroidUpdateHosts,
  http.Client Function() createClient = http.Client.new,
}) async {
  final update = await g3AndroidUpdateRequest<G3AndroidUpdate>(
      '/client/android/update.json', (response) async {
    final bytes = <int>[];
    await for (final chunk
        in response.stream.timeout(const Duration(seconds: 8))) {
      if (bytes.length + chunk.length > 16384) throw const FormatException();
      bytes.addAll(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic>) throw const FormatException();
    final version = data['version'];
    final digest = data['sha256'];
    final size = data['size'];
    if (version is! String ||
        !g3VersionIsValid(version) ||
        digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        size is! int ||
        size <= 0 ||
        size > g3MaximumUpdateArtifactSize) {
      throw const FormatException();
    }
    return (version: version, digest: digest, size: size);
  }, hosts: hosts, createClient: createClient);
  return g3VersionNewer(update.version, current) ? update : null;
}
