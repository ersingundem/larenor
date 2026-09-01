import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/proxmox/presentation/widgets/proxmox_field_label.dart';
import 'package:larenor/l10n/generated/app_localizations_en.dart';

void main() {
  final l10n = AppLocalizationsEn();

  group('proxmoxFieldLabel', () {
    test('maps common exact-match keys to friendly labels', () {
      expect(proxmoxFieldLabel(l10n, 'cores'), 'CPU cores');
      expect(proxmoxFieldLabel(l10n, 'ostype'), 'OS type');
      expect(proxmoxFieldLabel(l10n, 'onboot'), 'Start at boot');
    });

    test('maps numbered network interface keys with their index', () {
      expect(proxmoxFieldLabel(l10n, 'net0'), 'Network Interface 0');
      expect(proxmoxFieldLabel(l10n, 'net12'), 'Network Interface 12');
    });

    test('maps numbered storage keys with bus name and index', () {
      expect(proxmoxFieldLabel(l10n, 'scsi0'), 'SCSI Storage 0');
      expect(proxmoxFieldLabel(l10n, 'ide2'), 'IDE Storage 2');
      expect(proxmoxFieldLabel(l10n, 'virtio3'), 'VIRTIO Storage 3');
      expect(proxmoxFieldLabel(l10n, 'sata1'), 'SATA Storage 1');
    });

    test('maps mount points and unused disks', () {
      expect(proxmoxFieldLabel(l10n, 'mp0'), 'Mount Point 0');
      expect(proxmoxFieldLabel(l10n, 'unused1'), 'Unused Disk 1');
      expect(proxmoxFieldLabel(l10n, 'ipconfig0'), 'IP Configuration 0');
    });

    test('falls back to a Title Case prettification for unrecognized keys', () {
      expect(proxmoxFieldLabel(l10n, 'some_weird_key'), 'Some Weird Key');
      expect(proxmoxFieldLabel(l10n, 'lock'), 'Lock');
    });
  });

  test('proxmoxHiddenConfigKeys excludes digest from display', () {
    expect(proxmoxHiddenConfigKeys, contains('digest'));
  });
}
