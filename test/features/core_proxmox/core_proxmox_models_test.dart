import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/core_proxmox/domain/core_proxmox_models.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

void main() {
  final fixture = jsonDecode(
    File('contracts/proxmox-resource.v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final context = ServerContext.fromJson(fixture['context']);
  final target = HomeResourceRecord.fromJson(
    fixture['resource'],
    expectedContext: context,
  );

  test('strict typed snapshot preserves node guest and storage summaries', () {
    final value = CoreProxmoxSnapshot.fromJson(
      fixture['snapshot'],
      target: target,
    );
    expect(value.bindingId, '5' * 32);
    expect(value.serviceId, '4' * 32);
    expect(value.remainingTtl, const Duration(seconds: 5));
    expect(value.summary.nodes.map((e) => e.status), [
      CoreProxmoxNodeStatus.online,
      CoreProxmoxNodeStatus.offline,
    ]);
    expect(value.summary.guests.map((e) => (e.kind, e.status)), [
      (CoreProxmoxGuestKind.qemu, CoreProxmoxGuestStatus.running),
      (CoreProxmoxGuestKind.lxc, CoreProxmoxGuestStatus.stopped),
    ]);
    expect(value.summary.storages.single.usedRatio, .5);
    expect(value.summary.recentTasks.first.kind, 'vzdump');
    expect(
      value.summary.recentTasks.first.status,
      CoreProxmoxTaskStatus.succeeded,
    );
    expect(
      value.summary.maintenance.state,
      CoreProxmoxMaintenanceState.critical,
    );
    expect(value.summary.maintenance.warningCount, 2);
    expect(value.summary.maintenance.warnings.map((warning) => warning.kind), [
      CoreProxmoxWarningKind.nodeOffline,
      CoreProxmoxWarningKind.recentTaskFailed,
    ]);
    expect(
      value.summary.protection.state,
      CoreProxmoxProtectionState.available,
    );
    expect(
      value.summary.protection.latestBackup?.status,
      CoreProxmoxTaskStatus.succeeded,
    );
    expect(value.summary.protection.snapshots.first.snapshotCount, 2);
    expect(value.toString(), 'CoreProxmoxSnapshot');
  });

  test('binding and preview require exact target and service tuple', () {
    final binding = CoreProxmoxBinding.fromJson(
      fixture['binding'],
      target: target,
    );
    final preview = CoreProxmoxPreview.fromJson({
      ...fixture['preview'] as Map,
      'binding': fixture['binding'],
      'summary': fixture['summary'],
    }, target: target);
    expect(preview.binding.sameBinding(binding), isTrue);
    expect(preview.summary.nodes, hasLength(2));
  });

  test('unknown duplicate stale and malformed metrics fail closed', () {
    Map<String, dynamic> snapshot() =>
        jsonDecode(jsonEncode(fixture['snapshot'])) as Map<String, dynamic>;
    final mutations = <void Function(Map<String, dynamic>)>[
      (v) =>
          ((v['summary'] as Map)['nodes'] as List).first['status'] = 'unknown',
      (v) => ((v['summary'] as Map)['guests'] as List).first['cpuRatio'] = 2,
      (v) =>
          ((v['summary'] as Map)['storages'] as List).first['usedBytes'] = -1,
      (v) => (v['summary'] as Map)['nodes'] = [
        ...((v['summary'] as Map)['nodes'] as List),
        ((v['summary'] as Map)['nodes'] as List).first,
      ],
      (v) => v['resourceRevision'] = target.revision - 1,
      (v) => v['aclRevision'] = target.aclRevision + 1,
      (v) => v['serviceId'] = 'x' * 32,
      (v) => v['extra'] = true,
      (v) => ((v['summary'] as Map)['recentTasks'] as List).first['status'] =
          'unknown',
      (v) => ((v['summary'] as Map)['recentTasks'] as List).first['actor'] =
          'root@pam',
      (v) => (v['summary'] as Map)['recentTasks'] = [
        ...((v['summary'] as Map)['recentTasks'] as List),
        ((v['summary'] as Map)['recentTasks'] as List).first,
      ],
      (v) => ((v['summary'] as Map)['maintenance'] as Map)['state'] = 'unknown',
      (v) => ((v['summary'] as Map)['maintenance'] as Map)['warningCount'] = 99,
      (v) =>
          (((v['summary'] as Map)['maintenance'] as Map)['warnings'] as List)
                  .first['rawError'] =
              'private',
      (v) =>
          ((((v['summary'] as Map)['maintenance'] as Map)['warnings']
                      as List)[1]
                  as Map)['severity'] =
              'critical',
      (v) => ((v['summary'] as Map)['protection'] as Map)['state'] =
          'unknown',
      (v) => ((v['summary'] as Map)['protection'] as Map)['guestCount'] = 3,
      (v) => ((v['summary'] as Map)['protection'] as Map)['host'] =
          'pve.internal',
      (v) =>
          (((v['summary'] as Map)['protection'] as Map)['latestBackup']
                  as Map)['taskId'] =
              '7' * 64,
      (v) =>
          ((((v['summary'] as Map)['protection'] as Map)['snapshots'] as List)
                  .first as Map)['vmId'] =
              999,
    ];
    for (final mutate in mutations) {
      final value = snapshot();
      mutate(value);
      expect(
        () => CoreProxmoxSnapshot.fromJson(value, target: target),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });
}
