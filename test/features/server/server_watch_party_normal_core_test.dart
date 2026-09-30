import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/watch_parties/data/server_watch_party_api.dart';
import 'package:larenor/features/server/watch_parties/data/server_watch_party_controller.dart';
import 'package:larenor/features/server/watch_parties/domain/server_watch_party_models.dart';

const _itemId = '55555555555555555555555555555555';

final class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? value) async {}
}

Future<ServerAccountController> _account(
  String coreUrl,
  String username,
  String password,
) async {
  final account = ServerAccountController(store: _Store());
  await account.signIn(
    baseUrl: coreUrl,
    username: username,
    password: password,
    deviceName: 'F21 $username client',
  );
  expect(account.failure, isNull);
  expect(account.session, isNotNull);
  return account;
}

String Function() _ids(int seed) {
  var value = seed;
  return () => (value++).toRadixString(16).padLeft(32, '0');
}

ServerWatchPartyTarget _target({required bool canSeek}) =>
    ServerWatchPartyTarget(
      targetId: canSeek ? 'living-room' : 'kitchen-display',
      targetRevision: 1,
      canSeek: canSeek,
      canPause: true,
    );

const _leaderPlayback = ServerWatchPartyPlayback(
  state: ServerWatchPartyPlaybackState.playing,
  positionMs: 120000,
  measuredRoundTripMs: 40,
);

const _followerPlayback = ServerWatchPartyPlayback(
  state: ServerWatchPartyPlaybackState.playing,
  positionMs: 0,
  measuredRoundTripMs: 80,
);

void main() {
  final phase = Platform.environment['LARENOR_F21_PHASE'];
  final coreUrl = Platform.environment['LARENOR_F21_CORE_URL'];
  final statePath = Platform.environment['LARENOR_F21_STATE'];
  final memberPassword = Platform.environment['LARENOR_F21_MEMBER_PASSWORD'];
  setUpAll(() => HttpOverrides.global = null);

  test(
    'two production Clients use normal Core authority and restart recovery',
    () async {
      final leaderAccount = await _account(
        coreUrl!,
        'admin',
        'Synthetic new password 2026',
      );
      final followerAccount = await _account(
        coreUrl,
        'watch-member',
        memberPassword!,
      );
      addTearDown(leaderAccount.dispose);
      addTearDown(followerAccount.dispose);
      final leaderSession = leaderAccount.session!;
      final followerSession = followerAccount.session!;

      if (phase == 'prepare') {
        final leader = ServerWatchPartyController(leaderAccount);
        final follower = ServerWatchPartyController(followerAccount);
        addTearDown(leader.dispose);
        addTearDown(follower.dispose);

        await leader.createCurrentItem(_itemId, current: () => true);
        expect(leader.failure, isNull);
        final invitation = leader.invitation!;
        await follower.join(
          invitation.value,
          itemId: _itemId,
          current: () => true,
        );
        expect(follower.failure, isNull);

        await leader.refresh(current: () => true);
        await leader.report(
          target: _target(canSeek: true),
          playback: _leaderPlayback,
          current: () => true,
        );
        expect(leader.failure, isNull);

        await leader.command(
          action: 'seek',
          position: const Duration(seconds: 120),
          current: () => true,
        );
        expect(leader.failure, isNull);

        // The follower still holds the pre-command room revision. The normal
        // Core must reject it, after which an explicit refresh can reconcile.
        await follower.report(
          target: _target(canSeek: false),
          playback: _followerPlayback,
          current: () => true,
        );
        expect(follower.failure, 'conflict');
        await follower.refresh(current: () => true);
        await follower.report(
          target: _target(canSeek: false),
          playback: _followerPlayback,
          current: () => true,
        );
        expect(follower.failure, isNull);

        await leader.refresh(current: () => true);
        await leader.command(
          action: 'seek',
          position: const Duration(seconds: 121),
          current: () => true,
        );
        await follower.refresh(current: () => true);
        expect(
          follower.snapshot!.directive!.action,
          ServerWatchPartyDirectiveAction.unsupported,
        );

        await File(statePath!).writeAsString(
          jsonEncode({
            'roomId': leader.snapshot!.roomId,
            'invitation': leader.invitation!.value,
          }),
          flush: true,
        );
      } else {
        expect(phase, 'restart');
        final state = Map<String, Object?>.from(
          jsonDecode(await File(statePath!).readAsString()) as Map,
        );
        final invitation = ServerWatchPartyInvitation.parse(
          state['invitation']! as String,
        );
        final leaderApi = ServerWatchPartyApi(
          await leaderAccount.withSession((api, _) async => api),
          leaderSession,
          requestId: _ids(300),
        );
        final followerApi = ServerWatchPartyApi(
          await followerAccount.withSession((api, _) async => api),
          followerSession,
          requestId: _ids(400),
        );
        final revokedTransport = LarenorServerApi(
          endpoint: followerSession.endpoint,
        );
        addTearDown(revokedTransport.close);
        final revokedApi = ServerWatchPartyApi(
          revokedTransport,
          followerSession,
          requestId: _ids(500),
        );

        // New session families must explicitly rejoin with the retained
        // invitation before accessing the durable room.
        final leader = await leaderApi.join(invitation);
        final currentInvitation = ServerWatchPartyInvitation(
          roomId: invitation.roomId,
          roomRevision: leader.revision,
          itemId: invitation.itemId,
          inviteCode: invitation.inviteCode,
        );
        var follower = await followerApi.join(currentInvitation);
        var leaderFresh = await leaderApi.refresh(invitation.roomId);
        leaderFresh = await leaderApi.command(
          snapshot: leaderFresh,
          action: 'play',
          positionMs: 121000,
        );
        expect(leaderFresh.leaderAccountId, leaderSession.user.id);

        follower = await followerApi.refresh(invitation.roomId);
        final promoted = await leaderApi.transfer(
          snapshot: await leaderApi.refresh(invitation.roomId),
          nextLeader: follower.self(followerSession.user.id),
        );
        expect(promoted.leaderAccountId, followerSession.user.id);

        final followerLeader = await followerApi.refresh(invitation.roomId);
        await followerApi.command(
          snapshot: followerLeader,
          action: 'pause',
          positionMs: 121000,
        );
        await leaderApi.leave(await leaderApi.refresh(invitation.roomId));
        final remaining = await followerApi.refresh(invitation.roomId);
        expect(remaining.leaderAccountId, followerSession.user.id);
        expect(remaining.participants, hasLength(1));

        await followerAccount.signOut();
        await expectLater(
          revokedApi.refresh(invitation.roomId),
          throwsA(
            isA<LarenorServerException>().having(
              (error) => error.code,
              'code',
              'unauthorized',
            ),
          ),
        );
      }
    },
    skip:
        phase == null ||
            coreUrl == null ||
            statePath == null ||
            memberPassword == null
        ? 'Requires explicit normal Core F21 runner'
        : false,
  );
}
