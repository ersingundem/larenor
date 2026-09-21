import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/core_backups/data/server_core_backups_controller.dart';
import 'package:larenor/features/server/core_backups/domain/server_core_backup_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'server_admin_test_support.dart';

Map<String, dynamic> backupManifest() => {
  'contractVersion': 1,
  'snapshotId': '1' * 32,
  'createdAt': 1789952400,
  'coreVersion': '0.5.0',
  'databaseSchemaVersion': 61,
  'componentSchemaVersions': {'auth': 1, 'vault': 1},
  'resources': [
    {
      'id': 'component-index',
      'kind': 'componentData',
      'version': '1',
      'byteLength': 80,
      'sha256': '1' * 64,
    },
    {
      'id': 'core-configuration',
      'kind': 'configuration',
      'version': '1',
      'byteLength': 120,
      'sha256': '2' * 64,
    },
    {
      'id': 'core-database',
      'kind': 'database',
      'version': '61',
      'byteLength': 4096,
      'sha256': '3' * 64,
    },
    {
      'id': 'vault-key',
      'kind': 'vaultKey',
      'version': 'aes256-v1',
      'byteLength': 32,
      'sha256': '4' * 64,
    },
  ],
};

Map<String, dynamic> readyPlan() => {
  'status': 'ready',
  'blockers': <String>[],
  'manifest': backupManifest(),
};

final class BackupFixture extends AdminFixture {
  BackupFixture() {
    respond = (request) async {
      if (request.url.path.endsWith('/context')) {
        return defaultResponse(request);
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/admin/backups/plan')) {
        return pending?.future ?? json(response);
      }
      return json({
        'error': {'code': 'not_found'},
      }, 404);
    };
  }

  Map<String, dynamic> response = readyPlan();
  Completer<http.Response>? pending;
}

void main() {
  test('plan parser accepts only exact bounded backup metadata', () {
    final plan = CoreBackupPlan.fromJson(readyPlan());
    expect(plan.ready, isTrue);
    expect(plan.manifest!.totalBytes, 4328);
    expect(plan.manifest!.resources.map((item) => item.kind), {
      CoreBackupResourceKind.componentData,
      CoreBackupResourceKind.configuration,
      CoreBackupResourceKind.database,
      CoreBackupResourceKind.vaultKey,
    });
    expect(plan.toString(), isNot(contains('111111111')));
    expect(plan.manifest.toString(), 'CoreBackupManifest');

    final blocked = CoreBackupPlan.fromJson({
      'status': 'blocked',
      'blockers': ['active_plugin_job'],
      'manifest': null,
    });
    expect(blocked.ready, isFalse);

    for (final invalid in <Map<String, dynamic>>[
      {...readyPlan(), 'secret': 'leak'},
      {...readyPlan(), 'status': 'blocked'},
      {
        ...readyPlan(),
        'blockers': ['unknown_operation'],
      },
      {
        ...readyPlan(),
        'manifest': {...backupManifest(), 'contractVersion': 2},
      },
      {
        ...readyPlan(),
        'manifest': {
          ...backupManifest(),
          'resources': [
            for (final item in backupManifest()['resources']! as List)
              if ((item as Map)['id'] == 'vault-key')
                {...item, 'version': 'plaintext'}
              else
                item,
          ],
        },
      },
    ]) {
      expect(
        () => CoreBackupPlan.fromJson(invalid),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });

  test(
    'controller binds the read to current admin session and visibility',
    () async {
      final fixture = BackupFixture();
      await fixture.account.initialize();
      final controller = ServerCoreBackupsController(fixture.account);
      addTearDown(() {
        controller.dispose();
        fixture.account.dispose();
      });

      await controller.load(current: () => true);
      expect(controller.plan?.ready, isTrue);
      expect(fixture.adminCalls.single.method, 'GET');
      expect(fixture.mutations, isEmpty);
      expect(
        fixture.adminCalls.single.headers['authorization'],
        'Bearer synthetic_admin_access_12345',
      );

      fixture.response = {...readyPlan(), 'status': 'invalid'};
      await controller.load(current: () => true);
      expect(controller.plan, isNull);
      expect(controller.failure, 'invalid_response');

      fixture.pending = Completer<http.Response>();
      final pending = controller.load(current: () => true);
      controller.invalidate();
      fixture.pending!.complete(
        fixture.json({
          'status': 'blocked',
          'blockers': ['active_plugin_job'],
          'manifest': null,
        }),
      );
      await pending;
      expect(controller.plan, isNull);
      expect(controller.failure, isNull);
    },
  );

  test('member account cannot dispatch backup readiness reads', () async {
    final fixture = BackupFixture();
    fixture.user = ServerUser(
      id: adminId,
      username: 'member',
      role: ServerRole.member,
      mustChangePassword: false,
    );
    fixture.store.value = fixture.session();
    await fixture.account.initialize();
    final controller = ServerCoreBackupsController(fixture.account);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });
    await controller.load(current: () => true);
    expect(fixture.adminCalls, isEmpty);
    expect(controller.plan, isNull);
  });
}
