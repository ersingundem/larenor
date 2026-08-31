import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/proxmox/data/models/proxmox_storage.dart';

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
}
