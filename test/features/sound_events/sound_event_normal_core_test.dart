import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/sound_events/data/core_sound_event_api.dart';

class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;
  @override
  Future<void> write(ServerSession? value) async {}
}

void main() {
  final url = Platform.environment['LARENOR_SOUND_CORE_URL'];
  setUpAll(() => HttpOverrides.global = null);
  test(
    'actual Client → normal Core → HA/Frigate source and exact review refresh',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Sound event gate',
      );
      expect(account.failure, isNull);
      final api = CoreSoundEventApi(account: account, isCurrent: () => true);
      addTearDown(api.retire);
      final initial = await api.bootstrap();
      expect(initial.sourceStatus.state, 'unavailable');
      final local = await api.loadSourceSetup();
      expect(local.discoveryVerified, isFalse);
      expect(local.cameras, isEmpty);
      final setup = await api.discoverSourceSetup();
      expect(setup.discoveryVerified, isTrue);
      final camera = setup.cameras.firstWhere(
        (item) => item.label == 'Front door',
      );
      final room = setup.rooms.single;
      expect(camera.audioLabels, containsAll(['bark', 'fire_alarm']));
      final saved = await api.configureSource(
        current: setup,
        camera: camera,
        room: room,
        barkLabels: const ['bark'],
        noiseLabels: const ['fire_alarm'],
        consentGranted: true,
        retentionSeconds: 86400,
      );
      expect(saved.configuration?.consentGranted, isTrue);
      final snapshot = await api.refreshSource();
      expect(snapshot.sourceStatus.state, 'ready');
      expect(snapshot.sourceStatus.silenceProven, isFalse);
      expect(snapshot.sourceStatus.clipAvailable, isFalse);
      expect(snapshot.events.map((item) => item.className).toSet(), {
        'bark',
        'noise',
      });
      expect(snapshot.events.every((item) => !item.automationVerified), isTrue);
    },
    skip: url == null ? 'Requires explicit isolated normal Core runner' : false,
  );
}
