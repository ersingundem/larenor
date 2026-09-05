import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_storage.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_guest.dart';

void main() {
  test('parses content types and computes usedFraction', () {
    final storage = ProxmoxStorage.fromJson({
      'storage': 'local',
      'type': 'dir',
      'content': 'images,rootdir,vztmpl,backup',
      'total': 1000,
      'used': 250,
      'avail': 750,
      'active': 1,
      'enabled': 1,
    });

    expect(storage.name, 'local');
    expect(storage.contentTypes, ['images', 'rootdir', 'vztmpl', 'backup']);
    expect(storage.usedFraction, 0.25);
    expect(storage.supportsBackups, isTrue);
    expect(storage.supportsTemplates, isTrue);
    expect(storage.active, isTrue);
  });

  test('supportsBackups/supportsTemplates are false when absent', () {
    final storage = ProxmoxStorage.fromJson({
      'storage': 'iso-only',
      'type': 'dir',
      'content': 'iso',
    });

    expect(storage.supportsBackups, isFalse);
    expect(storage.supportsTemplates, isFalse);
  });

  test('usedFraction is null without a total', () {
    final storage = ProxmoxStorage.fromJson({
      'storage': 'x',
      'type': 'dir',
      'content': '',
    });
    expect(storage.usedFraction, isNull);
  });
  test('clone storage matches guest content type and availability', () {
    final images = ProxmoxStorage.fromJson({
      'storage': 'images',
      'active': 1,
      'enabled': 1,
      'content': 'images',
    });
    final containers = ProxmoxStorage.fromJson({
      'storage': 'ct',
      'active': 1,
      'enabled': 1,
      'content': 'rootdir',
    });
    final offline = ProxmoxStorage.fromJson({
      'storage': 'offline',
      'content': 'images,rootdir,backup',
      'active': 0,
    });
    final disabled = ProxmoxStorage.fromJson({
      'storage': 'disabled',
      'content': 'images,rootdir,backup',
      'enabled': 0,
    });
    expect(images.supportsGuestType(ProxmoxGuestType.qemu), isTrue);
    expect(images.supportsGuestType(ProxmoxGuestType.lxc), isFalse);
    expect(containers.supportsGuestType(ProxmoxGuestType.lxc), isTrue);
    expect(containers.supportsGuestType(ProxmoxGuestType.qemu), isFalse);
    for (final storage in [offline, disabled]) {
      expect(storage.supportsGuestType(ProxmoxGuestType.qemu), isFalse);
      expect(storage.supportsGuestType(ProxmoxGuestType.lxc), isFalse);
      expect(storage.supportsBackups, isFalse);
    }
  });
}
