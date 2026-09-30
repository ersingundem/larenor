import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_catalog/domain/server_media_catalog_models.dart';
import 'package:larenor/features/server/personal_channels/data/server_personal_channel_api.dart';
import 'package:larenor/features/server/personal_channels/domain/server_personal_channel_models.dart';

final class _Store implements ServerSessionPersistence {
  _Store(this.file);

  final File file;

  @override
  Future<ServerSession?> read() async => file.existsSync()
      ? ServerSession.decodeStorage(await file.readAsString())
      : null;

  @override
  Future<void> write(ServerSession? value) async {
    if (value == null) {
      if (file.existsSync()) await file.delete();
    } else {
      await file.writeAsString(value.encodeStorage(), flush: true);
    }
  }
}

void main() {
  final coreUrl = Platform.environment['LARENOR_F22_CORE_URL'];
  final phase = Platform.environment['LARENOR_F22_PHASE'];
  final stateFile = Platform.environment['LARENOR_F22_STATE_FILE'];
  final sessionFile = Platform.environment['LARENOR_F22_SESSION_FILE'];
  final sourceJson = Platform.environment['LARENOR_F22_SOURCE'];

  setUpAll(() => HttpOverrides.global = null);

  test(
    'real Client starts, restores and cancels continuous personal channel',
    () async {
      final account = ServerAccountController(
        store: _Store(File(sessionFile!)),
      );
      addTearDown(account.dispose);
      if (phase == 'prepare') {
        await account.signIn(
          baseUrl: coreUrl!,
          username: 'admin',
          password: 'Synthetic new password 2026',
          deviceName: 'Personal channel acceptance',
        );
      } else {
        await account.initialize();
      }
      expect(account.failure, isNull);
      final ids = <String>['1' * 32, '2' * 32, '3' * 32, '4' * 32].iterator;
      String nextId() {
        expect(ids.moveNext(), isTrue);
        return ids.current;
      }

      late final ServerPersonalChannelApi client;
      await account.withSession((api, session) async {
        client = ServerPersonalChannelApi(api, session, requestId: nextId);
      });
      if (phase == 'prepare') {
        final source = jsonDecode(sourceJson!) as Map<String, dynamic>;
        final page = ServerMediaCatalogPage.fromJson(
          source['page'],
          query: '',
          mediaKind: null,
        );
        final selected = ServerPersonalChannelSource.fromCatalog(
          page,
          page.items.single,
          duration: const Duration(seconds: 60),
        );
        final second = ServerPersonalChannelSource.fromCatalog(
          page,
          page.items.single,
          duration: const Duration(seconds: 60),
        );
        final channel = await client.create(
          name: 'Continuous cinema',
          startsAt: DateTime.fromMillisecondsSinceEpoch(
            (source['startsAt'] as int) * 1000,
            isUtc: true,
          ),
          loop: true,
          sources: [selected, second],
          current: () => true,
        );
        final now = DateTime.fromMillisecondsSinceEpoch(
          (source['now'] as int) * 1000,
          isUtc: true,
        );
        final programme = channel.liveAt(now)!;
        final playback = await client.resolve(
          channel: channel,
          programme: programme,
          mode: ServerPersonalPlaybackMode.live,
          current: () => true,
        );
        final execution = await client.startContinuous(
          source: playback,
          targetId: 'jellyfin-player:living-room',
          current: () => true,
        );
        expect(execution.state, ServerPersonalExecutionState.active);
        expect(
          execution.code,
          ServerPersonalExecutionCode.authenticatedReadback,
        );
        await File(stateFile!).writeAsString(
          jsonEncode({
            'channelId': channel.id,
            'firstProgrammeId': programme.id,
            'firstExecutionRevision': execution.revision,
          }),
          flush: true,
        );
      } else {
        final saved = jsonDecode(
          await File(stateFile!).readAsString(),
        ) as Map<String, dynamic>;
        final channelId = saved['channelId'] as String;
        final channel = await client.read(channelId, current: () => true);
        expect(channel.state, ServerPersonalChannelState.active);
        final execution = await client.readContinuous(
          channelId,
          current: () => true,
        );
        expect(execution.state, ServerPersonalExecutionState.active);
        expect(
          execution.code,
          ServerPersonalExecutionCode.authenticatedReadback,
        );
        expect(execution.programmeId, isNot(saved['firstProgrammeId']));
        expect(
          execution.revision,
          greaterThan(saved['firstExecutionRevision'] as int),
        );
        final stopped = await client.stopContinuous(
          execution,
          current: () => true,
        );
        expect(stopped.state, ServerPersonalExecutionState.cancelled);
        expect(stopped.code, ServerPersonalExecutionCode.cancelled);
      }
    },
    skip:
        coreUrl == null ||
            phase == null ||
            stateFile == null ||
            sessionFile == null ||
            sourceJson == null
        ? 'Requires explicit isolated F22 normal Core runner'
        : false,
  );
}
