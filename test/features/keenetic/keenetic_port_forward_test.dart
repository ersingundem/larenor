import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/keenetic/data/models/keenetic_port_forward.dart';

void main() {
  test('label prefers a non-empty comment', () {
    final rule = KeeneticPortForward.fromJson({
      'protocol': 'tcp',
      'port': 8080,
      'to': '192.168.1.50',
      'comment': 'Home Assistant',
    });
    expect(rule.label, 'Home Assistant');
    expect(rule.toAddress, '192.168.1.50');
  });

  test('label falls back to protocol:port when there is no comment', () {
    final rule = KeeneticPortForward.fromJson({
      'protocol': 'udp',
      'port': 51820,
    });
    expect(rule.label, 'udp :51820');
  });

  test('parses documented NAT argument names and translated ports', () {
    final rule = KeeneticPortForward.fromJson({
      'protocol': 'tcp',
      'interface': 'ISP',
      'port': 8080,
      'end-port': 8090,
      'address': '203.0.113.1',
      'to-address': '192.168.1.50',
      'to-port': 80,
    });
    expect(rule.portRange, '8080–8090');
    expect(rule.destination, '192.168.1.50:80');
    expect(rule.interfaceId, 'ISP');
  });

  test('source address is not misrepresented as destination', () {
    final rule = KeeneticPortForward.fromJson({'address': '203.0.113.1'});
    expect(rule.toAddress, isNull);
    expect(rule.protocol, 'any');
  });
}
