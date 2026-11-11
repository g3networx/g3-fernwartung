import 'package:flutter_hbb/g3_android_update_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('tries the next cluster node after a missing or invalid response',
      () async {
    final attempted = <String>[];
    final data = await g3AndroidUpdateRequest(
      '/client/android/update.json',
      (response) async {
        final value = await response.stream.bytesToString();
        if (value != 'release') throw const FormatException();
        return value;
      },
      createClient: () => MockClient((request) async {
        attempted.add(request.url.host);
        expect(request.followRedirects, isFalse);
        if (attempted.length == 1) return http.Response('', 404);
        if (attempted.length == 2) return http.Response('wrong release', 200);
        return http.Response('release', 200);
      }),
    );
    expect(data, 'release');
    expect(attempted, g3AndroidUpdateHosts.take(3));
  });
}
