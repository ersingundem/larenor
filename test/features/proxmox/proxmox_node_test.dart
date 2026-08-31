import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_node.dart';

void main() {
  test('parses node list fields', () {
    final node = ProxmoxNode.fromJson({
      'node': 'pve1',
      'status': 'online',
      'cpu': 0.25,
      'maxcpu': 8,
      'mem': 4000000000,
      'maxmem': 16000000000,
      'disk': 50000000000,
      'maxdisk': 200000000000,
      'uptime': 123456,
    });

    expect(node.name, 'pve1');
    expect(node.isOnline, isTrue);
    expect(node.cpuFraction, 0.25);
    expect(node.maxCpu, 8);
    expect(node.memFraction, closeTo(0.25, 0.0001));
    expect(node.diskFraction, closeTo(0.25, 0.0001));
  });

  test('isOnline is false for any non-"online" status', () {
    final node = ProxmoxNode.fromJson({'node': 'pve2', 'status': 'offline'});
    expect(node.isOnline, isFalse);
  });

  test('memFraction/diskFraction are null without max values', () {
    final node = ProxmoxNode.fromJson({'node': 'pve1', 'status': 'online'});
    expect(node.memFraction, isNull);
    expect(node.diskFraction, isNull);
  });
}
