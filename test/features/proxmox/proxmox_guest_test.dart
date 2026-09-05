import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_guest.dart';

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

  test('missing optional fields remain unknown when identity is valid', () {
    final guest = ProxmoxGuest.fromJson(
      {'vmid': 100},
      type: ProxmoxGuestType.qemu,
      node: 'pve1',
    );
    expect(guest.vmid, 100);
    expect(guest.name, 'unknown');
    expect(guest.status, 'unknown');
    expect(guest.isTemplate, isFalse);
    expect(guest.memFraction, isNull);
  });
  test('power actions exclude templates and unknown states', () {
    ProxmoxGuest guest(String status, {bool template = false}) => ProxmoxGuest(
      type: ProxmoxGuestType.qemu,
      node: 'pve1',
      vmid: 100,
      name: 'VM',
      status: status,
      isTemplate: template,
    );
    expect(guest('stopped').powerActions, ['start']);
    expect(guest('paused').powerActions, ['resume', 'stop']);
    expect(guest('suspended').powerActions, ['resume', 'stop']);
    expect(guest('unknown').powerActions, isEmpty);
    expect(guest('stopped', template: true).powerActions, isEmpty);
    expect(guest('running').powerActions, isNot(contains('start')));
  });

  test('QEMU paused state takes precedence over process running state', () {
    final guest = ProxmoxGuest.fromJson(
      {'vmid': 100, 'status': 'running', 'qmpstatus': 'paused'},
      type: ProxmoxGuestType.qemu,
      node: 'pve1',
    );
    expect(guest.isRunning, isFalse);
    expect(guest.powerActions, contains('resume'));
  });
}
