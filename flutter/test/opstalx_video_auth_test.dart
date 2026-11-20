import 'package:flutter_hbb/desktop/widgets/opstalx_video_window.dart';
import 'package:flutter_hbb/g3_addressbook_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('offers the address book login when the native session is absent',
      () async {
    final api = G3AddressBookApi(client: MockClient((request) async {
      fail('VAS must use an authenticated address book request');
    }));
    addTearDown(api.close);

    expect(await requestOpsTalxRoom(api, null),
        {'error': 'Bitte im g3-Adressbuch anmelden.'});
  });

  test('reuses one native session and forwards only the selected customer',
      () async {
    final requests = <http.Request>[];
    final api = G3AddressBookApi(client: MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET') {
        return http.Response('{"customers":[{"id":1,"name":"Test"}]}', 200);
      }
      return http.Response(
          '{"url":"https://talx.opslinx.de/vas/launch#grant=fixture"}', 200);
    }))..token = 'address-book-session-fixture';
    addTearDown(api.close);

    expect((await requestOpsTalxRoom(api, null))['customers'], hasLength(1));
    expect(await requestOpsTalxRoom(api, 1), {
      'url': 'https://talx.opslinx.de/vas/launch#grant=fixture',
    });
    expect(requests.map((request) => request.url.path), [
      '/client-addressbook/vas/customers',
      '/client-addressbook/vas/start',
    ]);
    expect(requests.last.body, '{"customer_id":1}');
    for (final request in requests) {
      expect(request.url.host, 'linx.g3nx.net');
      expect(request.headers['Authorization'], 'Bearer ${api.token}');
    }
  });
}
