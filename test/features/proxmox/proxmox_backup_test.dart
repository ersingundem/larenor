import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_backup.dart';

void main() {
  test('parses volid/vmid/size and converts ctime to a DateTime', () {
    final backup = ProxmoxBackup.fromJson({
      'volid': 'local:backup/vzdump-qemu-100.vma.zst',
      'vmid': 100,
      'size': 2048,
      'ctime': 1735689600,
    });

    expect(backup.volumeId, 'local:backup/vzdump-qemu-100.vma.zst');
    expect(backup.vmid, 100);
    expect(backup.sizeBytes, 2048);
    expect(
      backup.createdAt,
      DateTime.fromMillisecondsSinceEpoch(1735689600 * 1000),
    );
  });

  test('createdAt is null without a ctime', () {
    final backup = ProxmoxBackup.fromJson({'volid': 'local:backup/x'});
    expect(backup.createdAt, isNull);
  });
}
