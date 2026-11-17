import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

class G3AndroidUpdateSignatureException implements Exception {
  const G3AndroidUpdateSignatureException();
}

Future<Uint8List> g3AndroidUpdateSignature(G3AndroidUpdate update) async {
  const limit = 64 * 1024;
  final build = RegExp(r'^\d+\.\d+\.\d+-g3\.\d+\.(\d+)$')
      .firstMatch(update.version)
      ?.group(1);
  if (build == null) throw const G3AndroidUpdateSignatureException();
  try {
    return await g3AndroidUpdateRequest(
        '/client/platform/android_arm64/$build.certum.p7s', (response) async {
      final length = response.contentLength;
      if (length != null && (length < 1 || length > limit)) {
        throw const FormatException();
      }
      final proof = BytesBuilder(copy: false);
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 8))) {
        if (proof.length + chunk.length > limit) throw const FormatException();
        proof.add(chunk);
      }
      if (proof.isEmpty) throw const FormatException();
      return proof.takeBytes();
    });
  } catch (_) {
    throw const G3AndroidUpdateSignatureException();
  }
}

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
