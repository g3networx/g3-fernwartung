import 'package:flutter_hbb/g3_system_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shows the primary IPv4 when the peer reports one', () {
    expect(g3RemoteIpv4({'ipv4': '172.20.94.44', 'local_ip': '10.0.0.1'}),
        '172.20.94.44');
  });

  test('supports older peers and rejects IPv6 in the IPv4 field', () {
    expect(g3RemoteIpv4({'local_ip': '10.0.0.1'}), '10.0.0.1');
    expect(g3RemoteIpv4({'local_ip': '2001:db8::1'}), '–');
    expect(g3RemoteIpv4({'ipv4': null, 'local_ip': '10.0.0.1'}), '–');
  });
}
