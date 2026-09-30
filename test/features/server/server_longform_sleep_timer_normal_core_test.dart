import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/music_manager/data/server_longform_session_api.dart';
import 'package:larenor/features/server/music_manager/data/server_music_manager_api.dart';
import 'package:larenor/features/server/music_manager/domain/server_longform_session_models.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';

final class _Store implements ServerSessionPersistence {
  _Store(this.value);

  ServerSession? value;

  @override
  Future<ServerSession?> read() async => value;

  @override
  Future<void> write(ServerSession? session) async => value = session;
}

void main() {
  final url = Platform.environment['LARENOR_F28_CORE_URL'];
  final phase = Platform.environment['LARENOR_F28_PHASE'];
  setUpAll(() => HttpOverrides.global = null);

  test(
    'real Client schedules and reads one durable authority-bound pause',
    () async {
      final stateFile = File(Platform.environment['LARENOR_F28_STATE_FILE']!);
      ServerSession? restored;
      if (phase == 'restart') {
        final storage =
            jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
        storage['baseUrl'] = url;
        restored = ServerSession.decodeStorage(jsonEncode(storage));
      }
      final account = ServerAccountController(store: _Store(restored));
      addTearDown(account.dispose);
      if (restored == null) {
        await account.signIn(
          baseUrl: url!,
          username: 'admin',
          password: 'Synthetic new password 2026',
          deviceName: 'Longform acceptance',
        );
      } else {
        await account.initialize();
      }
      expect(account.failure, isNull);

      await account.withSession((api, login) async {
        final managerApi = ServerMusicManagerApi(api, login.accessToken);
        late final ServerMusicManager manager;
        late final ServerMusicLongformCatalog catalog;
        try {
          manager = await managerApi.read(
            Platform.environment['LARENOR_F28_INSTALLATION_ID']!,
          );
        } catch (error) {
          throw StateError('manager read failed: $error');
        }
        try {
          catalog = await managerApi.inProgress(
            requestId: phase == 'schedule' ? '7' * 32 : '8' * 32,
            manager: manager,
            limit: 25,
            current: () => true,
          );
        } catch (error) {
          throw StateError('longform read failed: $error');
        }
        final item = catalog.items.single;
        final sessions = ServerLongformSessionApi(
          api,
          login.accessToken,
          requestId: phase == 'schedule' ? (() => '9' * 32) : (() => 'a' * 32),
        );
        final opened = await sessions.open(manager: manager, item: item);
        if (phase == 'schedule') {
          final scheduled =
              await ServerLongformSessionApi(
                api,
                login.accessToken,
                requestId: () => 'b' * 32,
              ).update(
                manager: manager,
                item: item,
                session: opened,
                positionSeconds: opened.positionSeconds,
                playbackState: ServerLongformPlaybackState.playing,
                bookmarks: opened.bookmarks,
                sleepTimerEndsAt: DateTime.fromMillisecondsSinceEpoch(
                  int.parse(Platform.environment['LARENOR_F28_DEADLINE']!) *
                      1000,
                  isUtc: true,
                ),
                sleepTimerReceiver: manager.receivers.first,
              );
          expect(scheduled.sleepTimerState, ServerLongformSleepState.scheduled);
          expect(scheduled.sleepTimerTargetId, 'homepod-living');
          await stateFile.writeAsString(account.session!.encodeStorage());
        } else {
          expect(opened.sleepTimerState, ServerLongformSleepState.enforced);
          expect(opened.sleepTimerCode, 'authenticated_readback');
          expect(opened.sleepTimerEndsAt, isNull);
          expect(opened.sleepTimerTargetId, isNull);
        }
      });
    },
    skip: url == null
        ? 'Run with server/tests/support/f28_flutter_acceptance.py'
        : false,
  );
}
