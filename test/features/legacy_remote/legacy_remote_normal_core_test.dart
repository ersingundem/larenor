import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/legacy_remote/data/legacy_remote_management_api.dart';
import 'package:larenor/features/legacy_remote/domain/legacy_remote_models.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;
  @override
  Future<void> write(ServerSession? value) async {}
}

void main() {
  final url = Platform.environment['LARENOR_REMOTE_CORE_URL'];
  setUpAll(() => HttpOverrides.global = null);
  test(
    'actual Client → normal Core → TCP/WS Broadlink mapping, send and durable uncertain readback',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'IR gate',
      );
      expect(account.failure, isNull);
      final api = CoreLegacyRemoteManagementApi(
        account: account,
        routeId: '56565656565656565656565656565656',
        sessionRevision: 1,
        routeRevision: 1,
        isCurrent: () => true,
      );
      addTearDown(api.retire);
      final catalog = await api.bootstrap();
      expect(catalog.devices, isEmpty);
      final service = (await api.setupServices()).single;
      final source = await api.configureSource(
        service: service,
        name: 'Living room TV',
        entityId: 'remote.living_room_broadlink',
        learnedDeviceName: 'television',
        commandKey: LegacyRemoteCommandKey.powerToggle,
        learnedCommandName: 'power',
      );
      final expanded = await api.updateSourceCommands(
        source: source,
        upsert: {
          LegacyRemoteCommandKey.volumeUp: 'louder',
          LegacyRemoteCommandKey.mute: 'quiet',
        },
        remove: {},
      );
      expect(expanded.commandKeys, hasLength(3));
      final trimmed = await api.updateSourceCommands(
        source: expanded,
        upsert: {},
        remove: {LegacyRemoteCommandKey.mute},
      );
      expect(trimmed.commandKeys.toSet(), {
        LegacyRemoteCommandKey.powerToggle,
        LegacyRemoteCommandKey.volumeUp,
      });
      final device = (await api.list(catalog.authority)).single;
      final command = device.commands.singleWhere(
        (item) => item.key == LegacyRemoteCommandKey.volumeUp,
      );
      final preview = await api.preview(
        catalog.authority,
        device: device,
        command: command,
        repeats: 1,
        holdMs: 0,
      );
      final result = await api.confirm(catalog.authority, preview);
      expect(result.status, LegacyRemoteDispatchStatus.uncertain);
      expect(result.deliveryVerified, isFalse);
      expect(result.deviceStateVerified, isFalse);
      final readback = await api.readback(
        catalog.authority,
        requestId: preview.requestId,
      );
      expect(readback.status, LegacyRemoteDispatchStatus.uncertain);
      expect(
        (await api.confirm(catalog.authority, preview)).status,
        LegacyRemoteDispatchStatus.uncertain,
      );
      final learning = await api.learn(
        catalog.authority,
        device: device,
        key: LegacyRemoteCommandKey.volumeUp,
      );
      expect(learning.status, LegacyRemoteLearningStatus.uncertain);
      expect(learning.learningVerified, isFalse);
      expect(learning.bindingId, isNull);
      await expectLater(
        api.preview(
          catalog.authority,
          device: device,
          command: command,
          repeats: 1,
          holdMs: 0,
        ),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'revision_conflict',
          ),
        ),
      );
    },
    skip: url == null ? 'Requires explicit isolated normal Core runner' : false,
  );
}
