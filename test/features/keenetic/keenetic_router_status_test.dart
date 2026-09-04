import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/keenetic/data/models/keenetic_router_status.dart';

void main() {
  test('missing or malformed measurements remain unavailable', () {
    final router = KeeneticRouterStatus.fromJson({}, {
      'cpuload': 'invalid',
      'memory': 'invalid',
      'uptime': '-1',
    });
    expect(router.model, 'Keenetic');
    expect(router.cpuPercent, isNull);
    expect(router.memoryPercent, isNull);
    expect(router.uptimeSeconds, isNull);
  });

  test('zero memory total does not divide by zero', () {
    final router = KeeneticRouterStatus.fromJson({}, {
      'memory': '0/0',
      'uptime': '0',
    });
    expect(router.memoryPercent, isNull);
    expect(router.uptimeSeconds, 0);
  });
}
