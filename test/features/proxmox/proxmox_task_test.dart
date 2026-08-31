import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/proxmox/data/models/proxmox_task.dart';

void main() {
  test('a task with no status field is still running', () {
    final task = ProxmoxTask.fromJson({
      'upid': 'UPID:pve1:...',
      'type': 'qmstart',
      'id': '100',
      'user': 'root@pam',
      'starttime': 1000,
    });

    expect(task.isRunning, isTrue);
    expect(task.isSuccess, isFalse);
  });

  test('a finished successful task has status "OK"', () {
    final task = ProxmoxTask.fromJson({
      'upid': 'UPID:pve1:...',
      'type': 'qmstart',
      'status': 'OK',
      'starttime': 1000,
      'endtime': 1005,
    });

    expect(task.isRunning, isFalse);
    expect(task.isSuccess, isTrue);
  });

  test('a finished failed task has a non-OK status message', () {
    final task = ProxmoxTask.fromJson({
      'upid': 'UPID:pve1:...',
      'type': 'qmstart',
      'status': "command 'qm start 100' failed",
    });

    expect(task.isRunning, isFalse);
    expect(task.isSuccess, isFalse);
  });
}
