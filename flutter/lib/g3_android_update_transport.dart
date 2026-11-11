import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

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
