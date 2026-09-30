import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/tablet_fleet/data/server_tablet_fleet_api.dart';
import 'package:larenor/features/server/tablet_fleet/domain/server_tablet_fleet_models.dart';
import 'package:larenor/features/server/tablet_fleet/runtime/server_tablet_fleet_device_adapter.dart';
import 'package:larenor/features/server/tablet_fleet/runtime/tablet_fleet_device_runtime.dart';
import 'package:larenor/features/server/tablet_fleet/runtime/tablet_fleet_device_store.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_profile_store.dart';

const _registration = '53535353535353535353535353535353';

final class _FileSessionStore implements ServerSessionPersistence {
  const _FileSessionStore(this.file);
  final File file;

  @override
  Future<ServerSession?> read() async => file.existsSync()
      ? ServerSession.decodeStorage(await file.readAsString())
      : null;

  @override
  Future<void> write(ServerSession? value) async {
    if (value == null) {
      if (file.existsSync()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(value.encodeStorage(), flush: true);
  }
}

final class _FileDeviceStore implements TabletFleetDeviceStore {
  const _FileDeviceStore(this.file);
  final File file;

  @override
  Future<TabletFleetDeviceRecord?> read() async => file.existsSync()
      ? TabletFleetDeviceRecord.fromJson(jsonDecode(await file.readAsString()))
      : null;

  @override
  Future<void> write(TabletFleetDeviceRecord? value) async {
    if (value == null) {
      if (file.existsSync()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(value.toJson()), flush: true);
  }
}

final class _FileProfilePersistence implements ManagedTabletProfilePersistence {
  const _FileProfilePersistence(this.directory);
  final Directory directory;
  File get _profile => File('${directory.path}/profile.json');
  File get _confirmation => File('${directory.path}/profile.confirmation');
  @override
  Future<String?> read() async =>
      _profile.existsSync() ? _profile.readAsString() : null;
  @override
  Future<String?> readConfirmation() async =>
      _confirmation.existsSync() ? _confirmation.readAsString() : null;
  @override
  Future<void> write(String? value) async {
    if (value == null) {
      if (_profile.existsSync()) await _profile.delete();
    } else {
      await directory.create(recursive: true);
      await _profile.writeAsString(value, flush: true);
    }
  }

  @override
  Future<void> writeConfirmation(String? value) async {
    if (value == null) {
      if (_confirmation.existsSync()) await _confirmation.delete();
    } else {
      await directory.create(recursive: true);
      await _confirmation.writeAsString(value, flush: true);
    }
  }
}

final class _ObservedPlatform implements TabletFleetDevicePlatform {
  _ObservedPlatform(this.directory)
    : profiles = ManagedTabletProfileStore(_FileProfilePersistence(directory));
  final Directory directory;
  final ManagedTabletProfileStore profiles;
  File get effects => File('${directory.path}/effects.txt');
  File get activeProfile => File('${directory.path}/active-profile.txt');

  @override
  Future<TabletManagementMode> managementMode() async =>
      TabletManagementMode.standard;

  @override
  Future<TabletCommandResult> execute(
    TabletCommandKind command, {
    required bool Function() current,
  }) async {
    if (!current()) return TabletCommandResult.denied;
    if (command != TabletCommandKind.refreshDashboard) {
      return TabletCommandResult.unsupported;
    }
    final count = effects.existsSync()
        ? int.parse(await effects.readAsString())
        : 0;
    await effects.writeAsString('${count + 1}', flush: true);
    return current()
        ? TabletCommandResult.succeeded
        : TabletCommandResult.denied;
  }

  @override
  Future<TabletCommandResult> applyProfile({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
    required ManagedTabletProfilePublication publication,
    required bool Function() current,
  }) async {
    final authority = ManagedTabletProfileAuthority(
      serverBaseUrl: binding.serverBaseUrl,
      coreId: binding.coreId,
      homeId: binding.homeId,
      accountId: binding.accountId,
      deviceId: tablet.id,
      sourceId: 'fleet:${binding.sessionFamilyId}',
    );
    final applied = await profiles.applyForAuthority(
      authority,
      publication,
      expectedDeviceId: tablet.id,
      isCurrent: current,
      activate: (profile) async {
        if (!current()) throw StateError('retired');
        if (profile == null) {
          if (activeProfile.existsSync()) await activeProfile.delete();
        } else {
          await activeProfile.writeAsString('${profile.revision}', flush: true);
        }
      },
    );
    return current() && applied.revision == publication.revision
        ? TabletCommandResult.succeeded
        : TabletCommandResult.denied;
  }

  @override
  Future<void> restoreProfile({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
    required bool Function() current,
  }) async {
    final authority = ManagedTabletProfileAuthority(
      serverBaseUrl: binding.serverBaseUrl,
      coreId: binding.coreId,
      homeId: binding.homeId,
      accountId: binding.accountId,
      deviceId: tablet.id,
      sourceId: 'fleet:${binding.sessionFamilyId}',
    );
    final profile = await profiles.readForAuthority(authority);
    if (!current()) throw StateError('retired');
    if (profile == null) {
      if (activeProfile.existsSync()) await activeProfile.delete();
    } else {
      await activeProfile.writeAsString('${profile.revision}', flush: true);
    }
  }

  @override
  Future<void> retireProfile({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
  }) async {
    final authority = ManagedTabletProfileAuthority(
      serverBaseUrl: binding.serverBaseUrl,
      coreId: binding.coreId,
      homeId: binding.homeId,
      accountId: binding.accountId,
      deviceId: tablet.id,
      sourceId: 'fleet:${binding.sessionFamilyId}',
    );
    if (await profiles.readForAuthority(authority) != null &&
        activeProfile.existsSync()) {
      await activeProfile.delete();
    }
  }
}

void main() {
  final root = Platform.environment['LARENOR_F53_CLIENT_ROOT'];
  final url = Platform.environment['LARENOR_F53_CORE_URL'];
  final phase = Platform.environment['LARENOR_F53_PHASE'];
  setUpAll(() => HttpOverrides.global = null);

  test(
    'actual Client enrolls, resumes, consumes and revokes on normal Core',
    () async {
      final directory = Directory(root!);
      await directory.create(recursive: true);
      final account = ServerAccountController(
        store: _FileSessionStore(File('${directory.path}/session.json')),
      );
      addTearDown(account.dispose);
      if (phase == 'prepare') {
        await account.signIn(
          baseUrl: url!,
          username: 'admin',
          password: 'Synthetic new password 2026',
          deviceName: 'F53 actual tablet',
        );
      } else {
        await account.initialize();
      }
      expect(account.failure, isNull);
      final store = _FileDeviceStore(File('${directory.path}/device.json'));
      final runtime = TabletFleetDeviceRuntime(
        authority: ServerTabletFleetDeviceAuthority(account),
        store: store,
        platform: _ObservedPlatform(directory),
        registrationId: () => _registration,
        clientVersion: () async => '1.0.0+1',
      );
      addTearDown(runtime.dispose);
      await runtime.initialize();

      if (phase == 'prepare') {
        expect(runtime.enrolled, isFalse);
        await runtime.enroll('Actual kitchen tablet');
        expect(runtime.record!.binding.homeId, account.context!.homeId);
        expect(runtime.record!.tablet.mode, TabletManagementMode.standard);
        return;
      }

      expect(runtime.enrolled, isTrue);
      await runtime.synchronize();
      expect(runtime.failure, isNull);
      if (phase == 'consume') {
        expect(runtime.record!.tablet.desiredProfileRevision, 2);
        expect(runtime.record!.tablet.appliedProfileRevision, 2);
        expect(runtime.record!.pending, isNull);
        expect(runtime.record!.after, 1);
        expect(
          await File('${directory.path}/active-profile.txt').readAsString(),
          '2',
        );
        return;
      }

      if (phase == 'restart') {
        expect(runtime.record!.after, 1);
        expect(
          await File('${directory.path}/active-profile.txt').readAsString(),
          '2',
        );
        final context = account.context!;
        final wrong = ServerContext.fromJson({
          'schemaVersion': 1,
          'coreId': context.coreId,
          'homeId': 'f' * 32,
        });
        await expectLater(
          account.withSession(
            (raw, session) =>
                ServerTabletFleetApi(raw, session.accessToken, wrong).list(),
          ),
          throwsA(
            isA<LarenorServerException>().having(
              (error) => error.code,
              'code',
              'not_found',
            ),
          ),
        );
        return;
      }

      expect(phase, 'revoke');
      await runtime.revoke();
      expect(runtime.enrolled, isFalse);
      expect(await store.read(), isNull);
      expect(
        File('${directory.path}/active-profile.txt').existsSync(),
        isFalse,
      );
    },
    skip: root == null || url == null || phase == null
        ? 'Requires explicit isolated normal Core runner'
        : false,
  );
}
