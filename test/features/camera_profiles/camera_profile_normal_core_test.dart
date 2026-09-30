import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/camera_profiles/data/camera_profile_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;
  @override
  Future<void> write(ServerSession? value) async {}
}

void main() {
  final url = Platform.environment['LARENOR_CAMERA_CORE_URL'];
  // The suite's widget binding disables network by default. This dedicated
  // isolated Core gate intentionally uses real loopback TCP.
  setUpAll(() => HttpOverrides.global = null);
  test(
    'real Client → normal Core → HA registry/switch → readback and rollback',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Camera acceptance client',
      );
      expect(account.failure, isNull);
      expect(account.session, isNotNull);
      final api = CoreCameraProfileApi(
        account: account,
        routeId: '4' * 32,
        sessionRevision: 1,
        routeRevision: 1,
        isCurrent: () => true,
      );
      addTearDown(api.retire);
      final source = await api.sources();
      expect(source.revision, 1);
      expect(
        source.resources.where((item) => item.domain == 'switch'),
        hasLength(2),
      );
      // Opening settings retires the old profile route; returning creates a
      // fresh profile session, as CameraProfileRoute does in production.
      api.retire();
      final profileApi = CoreCameraProfileApi(
        account: account,
        routeId: '5' * 32,
        sessionRevision: 2,
        routeRevision: 2,
        isCurrent: () => true,
      );
      addTearDown(profileApi.retire);
      final snapshot = await profileApi.bootstrap();
      expect(snapshot.cameras, hasLength(1));
      expect(snapshot.hasUnsupported, isFalse);
      expect(snapshot.makesNoHardwarePrivacyClaim, isTrue);
      final receipt = await profileApi.apply(snapshot);
      expect(receipt.status, 'applied');
      expect(receipt.canRollback, isTrue);
      final rollback = await profileApi.rollback(snapshot, receipt);
      expect(rollback.status, 'restored');
      expect(await profileApi.sourceRecoveries(), isEmpty);
    },
    skip: url == null
        ? 'Run server/tests/support/f43_flutter_acceptance.py for the real isolated Core gate'
        : false,
  );
}
