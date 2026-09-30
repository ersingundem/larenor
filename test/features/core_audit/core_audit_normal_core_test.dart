import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/core_audit/data/core_audit_checkpoint_store.dart';
import 'package:larenor/features/core_audit/data/core_audit_controller.dart';
import 'package:larenor/features/server/admin/data/server_admin_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _SessionStore implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? session) async {}
}

/// Test-only durable stand-in for the platform secure-storage plugin. Core and
/// every transport remain production implementations; this file only crosses
/// the fresh Flutter process boundary that a platform keychain normally owns.
final class _FileCheckpointBackend implements CoreAuditCheckpointBackend {
  _FileCheckpointBackend(this.path);

  final File path;

  @override
  Future<String?> read(String key) async {
    if (!await path.exists()) return null;
    final raw = await path.readAsString();
    if (utf8.encode(raw).length > 8192) {
      throw const FormatException('checkpoint_fixture_too_large');
    }
    final value = jsonDecode(raw);
    if (value is! Map || value.length != 2 || value['key'] != key) {
      throw const FormatException('checkpoint_fixture_invalid');
    }
    final stored = value['value'];
    if (stored is! String) {
      throw const FormatException('checkpoint_fixture_invalid');
    }
    return stored;
  }

  @override
  Future<void> write(String key, String value) =>
      path.writeAsString(jsonEncode({'key': key, 'value': value}), flush: true);
}

Future<void> _settled(CoreAuditController controller) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while ((!controller.loaded || controller.busy) &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(controller.loaded, isTrue);
  expect(controller.busy, isFalse);
  expect(controller.failure, isNull);
  expect(controller.checkpointFailure, isNull);
  expect(controller.checkpointAlarm, isNull);
  expect(controller.verification, isNotNull);
}

Future<void> _createAuditedMember(
  ServerAccountController account,
  String username,
) => account.withSession((api, session) async {
  final created = await ServerAdminApi(api, session.accessToken).create(
    username: username,
    role: ServerRole.member,
    password: 'Synthetic temporary password 2026',
  );
  expect(created.username, username);
});

void main() {
  final coreUrl = Platform.environment['LARENOR_CORE_AUDIT_URL'];
  final phase = Platform.environment['LARENOR_CORE_AUDIT_PHASE'];
  final checkpointFile = Platform.environment['LARENOR_CORE_AUDIT_CHECKPOINT'];

  setUpAll(() => HttpOverrides.global = null);

  test(
    'real Client pins, rotates and compares Core audit across restart',
    () async {
      final account = ServerAccountController(store: _SessionStore());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: coreUrl!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Core audit acceptance',
      );
      expect(account.failure, isNull);
      final checkpointStore = CoreAuditCheckpointStore(
        backend: _FileCheckpointBackend(File(checkpointFile!)),
        clock: () => DateTime.utc(2026, 9, 30, 18),
      );
      final controller = CoreAuditController(account, checkpointStore);
      addTearDown(controller.dispose);
      await _settled(controller);

      if (phase == 'pin-rotate') {
        expect(controller.trustedCheckpoint, isNull);
        expect(controller.verification!.comparedCheckpoint, isFalse);
        expect(controller.canPin, isTrue);
        final initialSequence = controller.verification!.sequence;

        await controller.pinCurrent();
        await _settled(controller);
        expect(controller.trustedCheckpoint!.revision, 1);
        expect(controller.trustedCompared, isTrue);
        expect(controller.verification!.sequence, initialSequence);

        await _createAuditedMember(account, 'audit.acceptance.one');
        await controller.refresh();
        await _settled(controller);
        expect(controller.trustedCompared, isTrue);
        expect(controller.verification!.sequence, initialSequence + 1);
        expect(controller.canRotate, isTrue);

        await controller.rotateTrusted();
        await _settled(controller);
        expect(controller.trustedCheckpoint!.revision, 2);
        expect(
          controller.trustedCheckpoint!.sequence,
          controller.verification!.sequence,
        );
        expect(controller.trustedCompared, isTrue);
        expect(controller.canRotate, isFalse);
      } else {
        expect(phase, 'restart');
        final retained = controller.trustedCheckpoint!;
        expect(retained.revision, 2);
        expect(controller.trustedCompared, isTrue);
        expect(controller.verification!.comparedCheckpoint, isTrue);
        expect(controller.verification!.chainId, retained.chainId);
        expect(controller.verification!.sequence, retained.sequence);
        expect(controller.verification!.headHash, retained.headHash);

        await _createAuditedMember(account, 'audit.acceptance.two');
        await controller.refresh();
        await _settled(controller);
        expect(controller.trustedCheckpoint, retained);
        expect(controller.trustedCompared, isTrue);
        expect(controller.verification!.sequence, retained.sequence + 1);
        expect(controller.canRotate, isTrue);
      }
    },
    skip: coreUrl == null || phase == null || checkpointFile == null
        ? 'Requires explicit isolated normal Core runner'
        : false,
  );
}
