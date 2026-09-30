import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/epaper/data/epaper_account_api.dart';
import 'package:larenor/features/epaper/domain/epaper_management_models.dart';
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
  final url = Platform.environment['LARENOR_EPAPER_CORE_URL'];
  setUpAll(() => HttpOverrides.global = null);
  test(
    'actual Client → normal Core → HA/OpenEPaperLink preview and one send',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'E-paper gate',
      );
      expect(account.failure, isNull);
      final context = account.session!.context!;
      final api = await EpaperAccountApi.connect(
        account: account,
        context: context,
        routeId: 'a' * 32,
        isCurrent: () => true,
      );
      addTearDown(api.close);
      final sources = await api.discoverSources(api.authority);
      expect(sources, hasLength(1));
      final source = sources.single;
      expect(source.name, 'Hall display');
      expect(source.reachable, isTrue);
      final mapped = await api.map(
        api.authority,
        EpaperDeviceMappingDraft.fromSource(
          source,
          name: source.name,
          title: 'Larenor',
          value: '18 °C',
        ),
      );
      expect(mapped.capabilityVerified, isTrue);
      expect(mapped.supportedColors, ['black', 'white']);
      final preview = await api.preview(
        api.authority,
        deviceId: mapped.deviceId,
        expectedDeviceRevision: mapped.deviceRevision,
        action: EpaperManagementAction.refresh,
      );
      expect(preview.physicalDeliveryVerified, isFalse);
      final jpeg = await api.artifact(api.authority, preview);
      expect(jpeg.length, greaterThan(100));
      expect(jpeg.take(2), [0xff, 0xd8]);
      final receipt = await api.confirm(api.authority, preview);
      expect(receipt.status, EpaperCommandStatus.uncertain);
      expect(receipt.observedSnapshotDigest, preview.artifactDigest);
      final readback = await api.readback(
        api.authority,
        deviceId: mapped.deviceId,
      );
      expect(readback.verifiedDigest, isNull);
    },
    skip: url == null ? 'Requires explicit isolated normal Core runner' : false,
  );
}
