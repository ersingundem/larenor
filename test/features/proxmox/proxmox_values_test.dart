import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_guest.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_node.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_storage.dart';

void main() {
  test('template flag accepts JSON booleans without treating malformed values as a normal guest', () {
    expect(
      ProxmoxGuest.fromJson(
        {'vmid': 100, 'template': true},
        type: ProxmoxGuestType.qemu,
        node: 'pve',
      ).isTemplate,
      isTrue,
    );
    expect(
      () => ProxmoxGuest.fromJson(
        {'vmid': 100, 'template': 'unknown'},
        type: ProxmoxGuestType.qemu,
        node: 'pve',
      ),
      throwsFormatException,
    );
  });

  for (final value in [
    -1,
    double.nan,
    double.infinity,
    'unknown',
    9007199254740992,
  ]) {
    test('invalid numeric capacity stays unknown: $value', () {
      final node = ProxmoxNode.fromJson({
        'node': 'pve',
        'cpu': value,
        'mem': value,
        'uptime': value,
      });
      expect(node.cpuFraction, isNull);
      expect(node.mem, isNull);
      expect(node.uptimeSeconds, isNull);
    });
  }
  test('fractional counters, over-capacity ratios and unknown active flags are not zero/available', () {
    final node = ProxmoxNode.fromJson({
      'node': 'pve',
      'mem': 101,
      'maxmem': 100,
      'disk': 1.5,
      'cpu': 2,
    });
    expect(node.memFraction, isNull);
    expect(node.disk, isNull);
    expect(node.cpuFraction, isNull);
    final storage = ProxmoxStorage.fromJson({
      'storage': 'local',
      'content': 'backup,images',
      'used': 11,
      'total': 10,
    });
    expect(storage.activeState, isNull);
    expect(storage.enabledState, isNull);
    expect(storage.supportsBackups, isFalse);
    expect(storage.supportsGuestType(ProxmoxGuestType.qemu), isFalse);
    expect(storage.usedFraction, isNull);
  });
  test(
    'unknown identities do not become actionable guest zero or a fake node',
    () {
      expect(() => ProxmoxNode.fromJson({}), throwsFormatException);
      expect(() => ProxmoxStorage.fromJson({}), throwsFormatException);
      for (final id in [null, 0, 1.5, -1, double.infinity]) {
        expect(
          () => ProxmoxGuest.fromJson(
            {'vmid': id},
            type: ProxmoxGuestType.qemu,
            node: 'pve',
          ),
          throwsFormatException,
        );
      }
    },
  );
}
