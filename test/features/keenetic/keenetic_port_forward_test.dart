import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/keenetic/data/models/keenetic_port_forward.dart';

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
}
