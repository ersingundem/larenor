import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/music_manager/data/server_music_manager_controller.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';

class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;
  @override
  Future<void> write(ServerSession? value) async {}
}

void main() {
  final url = Platform.environment['LARENOR_F28_CORE_URL'];
  setUpAll(() => HttpOverrides.global = null);
  test(
    'ready member verifies and controls real runtime without admin setup',
    () async {
      SharedPreferences.setMockInitialValues({});
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.initialize();
      await account.signIn(
        baseUrl: url!,
        username: 'music-reader',
        password: 'Synthetic changed member password',
        deviceName: 'Member music gate',
      );
      expect(account.failure, isNull);
      expect(account.session!.user.role, ServerRole.member);
      final controller = ServerMusicManagerController(account);
      addTearDown(controller.dispose);
      await controller.load(current: () => true);
      expect(controller.failure, isNull);
      expect(controller.stored, true);
      await controller.verify(current: () => true);
      expect(controller.failure, isNull);
      expect(controller.verified, true);
      expect(controller.selectedReceiver!.kind, 'homepod');
      await controller.search('Member', current: () => true);
      expect(controller.failure, isNull);
      expect(controller.catalog!.items.single.name, 'Member result');
      await controller.command(ServerMusicOperation.pause, current: () => true);
      expect(controller.failure, isNull);
      expect(controller.lastReceipt!.state, 'succeeded');
      await account.withSession((api, session) async {
        await expectLater(
          api.request(
            'GET',
            '/admin/media/music-assistant/retained',
            token: session.accessToken,
          ),
          throwsA(isA<LarenorServerException>()),
        );
      });
    },
    skip: url == null ? 'Requires isolated normal Core runner' : false,
  );
}
