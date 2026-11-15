import 'package:flutter_hbb/g3_android_update_transport.dart';
import 'package:flutter_hbb/g3_update_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Android shows the actual build number for an update', () {
    expect(g3VersionLabel('1.5.3-g3.62.20083', useBuildNumber: true),
        'g3.6.2 Build 20083');
  });

  test('returns validated metadata only when the APK is newer', () async {
    const version = '1.5.3-g3.62.20074';
    final digest = List.filled(64, 'a').join();
    http.Client createClient() => MockClient((request) async {
          expect(request.url.path, '/client/android/update.json');
          return http.Response(
              '{"version":"$version","sha256":"$digest","size":123}', 200);
        });

    final update = await g3AvailableAndroidUpdate(
        current: '1.5.3-g3.62.20064', createClient: createClient);
    expect(update, (version: version, digest: digest, size: 123));
    expect(
        await g3AvailableAndroidUpdate(
            current: version, createClient: createClient),
        isNull);
  });

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
