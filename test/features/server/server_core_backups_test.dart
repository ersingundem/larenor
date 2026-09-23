import 'dart:async';
import 'dart:convert' show jsonDecode, utf8;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/core_backups/data/server_core_backups_controller.dart';
import 'package:larenor/features/server/core_backups/domain/server_core_backup_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'server_admin_test_support.dart';

Map<String, dynamic> backupManifest() => {
  'contractVersion': 2,
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
      'id': 'family-board',
      'kind': 'familyBoard',
      'version': '1',
      'byteLength': 1024,
      'sha256': '5' * 64,
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
      if (request.method == 'POST' &&
          request.url.path.endsWith('/admin/backups/export')) {
        return exportPending?.future ??
            http.Response.bytes(
              bundle,
              200,
              headers: {
                'content-type': 'application/vnd.larenor.core-backup',
                'content-disposition':
                    'attachment; filename="larenor-core-backup.larenor-core"',
                'cache-control': 'no-store',
                'x-content-type-options': 'nosniff',
              },
            );
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/admin/backups/restore/validate')) {
        return validationPending?.future ?? json(validationResponse);
      }
      return json({
        'error': {'code': 'not_found'},
      }, 404);
    };
  }

  Map<String, dynamic> response = readyPlan();
  Map<String, dynamic> validationResponse = {
    'compatible': true,
    'reasons': <String>[],
  };
  Uint8List bundle = Uint8List.fromList([
    ...utf8.encode('LARENOR-CORE-BACKUP\u0000\u0001'),
    ...List<int>.filled(64, 7),
  ]);
  Completer<http.Response>? pending;
  Completer<http.Response>? exportPending;
  Completer<http.Response>? validationPending;
}

void main() {
  test('plan parser accepts only exact bounded backup metadata', () {
    final plan = CoreBackupPlan.fromJson(readyPlan());
    expect(plan.ready, isTrue);
    expect(plan.manifest!.totalBytes, 5352);
    expect(plan.manifest!.resources.map((item) => item.kind), {
      CoreBackupResourceKind.componentData,
      CoreBackupResourceKind.configuration,
      CoreBackupResourceKind.database,
      CoreBackupResourceKind.familyBoard,
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
        'manifest': {...backupManifest(), 'contractVersion': 3},
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

  test('legacy four-resource Core backup remains readable', () {
    final legacy = {
      ...backupManifest(),
      'contractVersion': 1,
      'resources': [
        for (final item in backupManifest()['resources']! as List)
          if ((item as Map)['id'] != 'family-board') item,
      ],
    };
    final plan = CoreBackupManifest.fromJson(legacy);
    expect(plan.resources.length, 4);
    expect(plan.totalBytes, 4328);
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

  test('export keeps passphrase in the fixed body and returns only bounded ciphertext', () async {
    final fixture = BackupFixture();
    await fixture.account.initialize();
    final controller = ServerCoreBackupsController(fixture.account);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });
    const passphrase = 'Synthetic export passphrase 2026';

    final exported = await controller.export(passphrase, current: () => true);

    expect(exported!.bytes, fixture.bundle);
    expect(exported.filename, 'larenor-core-backup.larenor-core');
    final request = fixture.adminCalls.single;
    expect(request.url.path, endsWith('/admin/backups/export'));
    expect(request.url.query, isEmpty);
    expect(jsonDecode(request.body), {'passphrase': passphrase});
    expect(request.headers['authorization'], startsWith('Bearer '));
    expect(controller.toString(), isNot(contains(passphrase)));
    expect(exported.toString(), isNot(contains(passphrase)));
  });

  test(
    'restore preflight exposes exact incompatibility reasons without restore',
    () async {
      final fixture = BackupFixture()
        ..validationResponse = {
          'compatible': false,
          'reasons': [
            'core_version_mismatch',
            'database_schema_mismatch',
            'component_schema_mismatch',
          ],
        };
      await fixture.account.initialize();
      final controller = ServerCoreBackupsController(fixture.account);
      addTearDown(() {
        controller.dispose();
        fixture.account.dispose();
      });
      final manifest = CoreBackupManifest.fromJson(backupManifest());

      await controller.preflight(manifest, current: () => true);

      expect(controller.compatibility!.compatible, isFalse);
      expect(controller.compatibility!.reasons, {
        CoreBackupCompatibilityReason.coreVersion,
        CoreBackupCompatibilityReason.databaseSchema,
        CoreBackupCompatibilityReason.componentSchema,
      });
      final request = fixture.adminCalls.single;
      expect(request.url.path, endsWith('/admin/backups/restore/validate'));
      expect(request.url.query, isEmpty);
      expect(jsonDecode(request.body), {'manifest': backupManifest()});
      expect(
        fixture.adminCalls.where(
          (call) => !call.url.path.endsWith('/restore/validate'),
        ),
        isEmpty,
      );
    },
  );

  test('retired route drops delayed export and preflight results', () async {
    final fixture = BackupFixture();
    await fixture.account.initialize();
    final controller = ServerCoreBackupsController(fixture.account);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });

    fixture.exportPending = Completer<http.Response>();
    final export = controller.export(
      'Synthetic export passphrase 2026',
      current: () => true,
    );
    controller.invalidate();
    fixture.exportPending!.complete(
      http.Response.bytes(
        fixture.bundle,
        200,
        headers: {
          'content-type': 'application/vnd.larenor.core-backup',
          'content-disposition':
              'attachment; filename="larenor-core-backup.larenor-core"',
          'cache-control': 'no-store',
          'x-content-type-options': 'nosniff',
        },
      ),
    );
    expect(await export, isNull);

    fixture.exportPending = null;
    fixture.validationPending = Completer<http.Response>();
    final preflight = controller.preflight(
      CoreBackupManifest.fromJson(backupManifest()),
      current: () => true,
    );
    controller.invalidate();
    fixture.validationPending!.complete(
      fixture.json({'compatible': true, 'reasons': <String>[]}),
    );
    await preflight;
    expect(controller.compatibility, isNull);
    expect(controller.actionFailure, isNull);
  });

  test('binary envelope headers and compatibility shape fail closed', () async {
    final fixture = BackupFixture();
    await fixture.account.initialize();
    final controller = ServerCoreBackupsController(fixture.account);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/admin/backups/export')) {
        return http.Response.bytes(
          fixture.bundle,
          200,
          headers: {'content-type': 'application/octet-stream'},
        );
      }
      return fixture.json({
        'compatible': false,
        'reasons': ['unknown_mismatch'],
      });
    };
    expect(
      await controller.export(
        'Synthetic export passphrase 2026',
        current: () => true,
      ),
      isNull,
    );
    expect(controller.actionFailure, 'invalid_response');
    await controller.preflight(
      CoreBackupManifest.fromJson(backupManifest()),
      current: () => true,
    );
    expect(controller.compatibility, isNull);
    expect(controller.actionFailure, 'invalid_response');
  });
}
