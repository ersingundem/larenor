import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/proxmox/data/models/proxmox_guest.dart';

void main() {
  test('parses a running qemu guest', () {
    final guest = ProxmoxGuest.fromJson(
      {
        'vmid': 100,
        'name': 'web-server',
        'status': 'running',
        'cpu': 0.1,
        'maxcpu': 2,
        'mem': 500000000,
        'maxmem': 2000000000,
        'template': 0,
      },
      type: ProxmoxGuestType.qemu,
      node: 'pve1',
    );

    expect(guest.type, ProxmoxGuestType.qemu);
    expect(guest.node, 'pve1');
    expect(guest.vmid, 100);
    expect(guest.isRunning, isTrue);
    expect(guest.isTemplate, isFalse);
    expect(guest.memFraction, closeTo(0.25, 0.0001));
  });

  test('parses a stopped lxc template', () {
    final guest = ProxmoxGuest.fromJson(
      {'vmid': 200, 'name': 'ct-base', 'status': 'stopped', 'template': 1},
      type: ProxmoxGuestType.lxc,
      node: 'pve1',
    );

    expect(guest.type, ProxmoxGuestType.lxc);
    expect(guest.isRunning, isFalse);
    expect(guest.isTemplate, isTrue);
  });

  test('resourcePath and label differ by guest type', () {
    expect(ProxmoxGuestType.qemu.resourcePath, 'qemu');
    expect(ProxmoxGuestType.qemu.label, 'VM');
    expect(ProxmoxGuestType.lxc.resourcePath, 'lxc');
    expect(ProxmoxGuestType.lxc.label, 'Container');
  });

  test('defaults missing fields to safe values', () {
    final guest = ProxmoxGuest.fromJson(
      {},
      type: ProxmoxGuestType.qemu,
      node: 'pve1',
    );
    expect(guest.vmid, 0);
    expect(guest.name, 'unknown');
    expect(guest.status, 'unknown');
    expect(guest.isTemplate, isFalse);
    expect(guest.memFraction, isNull);
  });
}
