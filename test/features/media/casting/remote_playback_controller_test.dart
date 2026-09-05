import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/casting/domain/remote_playback_models.dart';
import 'package:larenor/features/media/data/media_api_exception.dart';

import 'remote_playback_fixture.dart';

Matcher failure(RemotePlaybackFailure value, {bool uncertain = false}) =>
    isA<RemotePlaybackException>()
        .having((error) => error.failure, 'failure', value)
        .having((error) => error.outcomeUnknown, 'outcomeUnknown', uncertain);
void main() {
  testWidgets(
    'discovery is lazy and shared; preparation gets current title before one explicit command',
    (tester) async {
      final api = FakeRemoteApi();
      final controller = remoteController(api);
      await controller.refresh();
      expect(api.reads, 0);
      final listener = controller.changes.listen((_) {});
      final second = controller.changes.listen((_) {});
      await tester.pump();
      expect(api.reads, 1);
      final intent = await controller.createIntent(
        controller.state.targets.single,
        itemId,
        startPosition: const Duration(seconds: 42),
      );
      expect(intent.itemTitle, 'Confirmed movie');
      expect(api.itemReads, 1);
      expect(api.commands, isEmpty);
      final receipt = await controller.play(intent);
      expect(api.itemReads, 2);
      expect(api.reads, 2);
      expect(api.commands.single.position, const Duration(seconds: 42));
      expect(receipt.status, RemotePlaybackReceiptStatus.accepted);
      expect(receipt.observedAt, isNull);
      unawaited(listener.cancel());
      unawaited(second.cancel());
      controller.dispose();
      await tester.pump();
    },
  );
  for (final unavailable in [
    playableItem.copyWith(type: 'Series'),
    playableItem.copyWith(isMissing: true),
    playableItem.copyWith(locationType: 'Virtual'),
    playableItem.copyWith(locationType: null),
    playableItem.copyWith(playAccess: null),
    playableItem.copyWith(playAccess: 'None'),
    playableItem.copyWith(mediaSourceCount: 0),
    playableItem.copyWith(id: otherItemId),
  ]) {
    testWidgets(
      'unavailable or unknown fresh item never sends playback (${unavailable.type}/${unavailable.locationType}/${unavailable.playAccess}/${unavailable.id})',
      (tester) async {
        final api = FakeRemoteApi();
        final controller = remoteController(api);
        final listener = controller.changes.listen((_) {});
        await tester.pump();
        final intent = await controller.createIntent(
          controller.state.targets.single,
          itemId,
        );
        api.item = unavailable;
        await expectLater(
          controller.play(intent),
          throwsA(failure(RemotePlaybackFailure.unsupportedItem)),
        );
        expect(api.commands, isEmpty);
        unawaited(listener.cancel());
        controller.dispose();
        await tester.pump();
      },
    );
  }
  for (final replacement in [
    <RemotePlaybackTarget>[],
    [target(user: otherUserId)],
    [target(device: 'different-device')],
    [target(server: 'different-server')],
  ]) {
    testWidgets(
      'immediate target recheck rejects vanished or replaced receiver ${replacement.map((value) => '${value.userId}/${value.deviceId}/${value.serverId}')}',
      (tester) async {
        final api = FakeRemoteApi();
        final controller = remoteController(api);
        final listener = controller.changes.listen((_) {});
        await tester.pump();
        final intent = await controller.createIntent(
          controller.state.targets.single,
          itemId,
        );
        api.targets = replacement;
        await expectLater(
          controller.play(intent),
          throwsA(failure(RemotePlaybackFailure.unavailable)),
        );
        expect(api.commands, isEmpty);
        unawaited(listener.cancel());
        controller.dispose();
        await tester.pump();
      },
    );
  }
  testWidgets(
    'expired, cross-controller and reused intents cannot dispatch; duplicate busy taps send once',
    (tester) async {
      var now = remoteNow;
      final api = FakeRemoteApi();
      final controller = remoteController(api, now: () => now);
      final other = remoteController(api, now: () => now);
      final listener = controller.changes.listen((_) {});
      final otherListener = other.changes.listen((_) {});
      await tester.pump();
      final expired = await controller.createIntent(
        controller.state.targets.single,
        itemId,
      );
      now = now.add(const Duration(seconds: 30));
      await expectLater(
        controller.play(expired),
        throwsA(failure(RemotePlaybackFailure.expiredIntent)),
      );
      final intent = await controller.createIntent(
        controller.state.targets.single,
        itemId,
      );
      await expectLater(
        other.play(intent),
        throwsA(failure(RemotePlaybackFailure.invalidIntent)),
      );
      api.playGate = Completer<void>();
      final first = controller.play(intent);
      await tester.pump();
      expect(api.commands, hasLength(1));
      await expectLater(
        controller.play(intent),
        throwsA(failure(RemotePlaybackFailure.busy)),
      );
      api.playGate!.complete();
      await first;
      await expectLater(
        controller.play(intent),
        throwsA(failure(RemotePlaybackFailure.invalidIntent)),
      );
      expect(api.commands, hasLength(1));
      unawaited(listener.cancel());
      unawaited(otherListener.cancel());
      controller.dispose();
      other.dispose();
      await tester.pump();
    },
  );
  for (final mode in ['background', 'hidden', 'disposed']) {
    testWidgets(
      '$mode invalidates an intent while its fresh item read is pending',
      (tester) async {
        final api = FakeRemoteApi();
        final controller = remoteController(api);
        final listener = controller.changes.listen((_) {});
        await tester.pump();
        final intent = await controller.createIntent(
          controller.state.targets.single,
          itemId,
        );
        api.itemGate = Completer<void>();
        final pending = expectLater(
          controller.play(intent),
          throwsA(failure(RemotePlaybackFailure.invalidIntent)),
        );
        await tester.pump();
        switch (mode) {
          case 'background':
            controller.setForeground(false);
          case 'hidden':
            controller.setVisible(false);
          case 'disposed':
            controller.dispose();
        }
        api.itemGate!.complete();
        await pending;
        await tester.pump();
        expect(api.commands, isEmpty);
        expect(controller.state.receipt, isNull);
        unawaited(listener.cancel());
        controller.dispose();
        await tester.pump();
      },
    );
  }
  testWidgets('account identity change during preflight prevents dispatch', (
    tester,
  ) async {
    var current = true;
    final api = FakeRemoteApi();
    final controller = remoteController(api, isCurrent: () => current);
    final listener = controller.changes.listen((_) {});
    await tester.pump();
    final intent = await controller.createIntent(
      controller.state.targets.single,
      itemId,
    );
    api.targetGate = Completer<void>();
    final pending = expectLater(
      controller.play(intent),
      throwsA(failure(RemotePlaybackFailure.invalidIntent)),
    );
    await tester.pump();
    current = false;
    api.targetGate!.complete();
    await pending;
    expect(api.commands, isEmpty);
    unawaited(listener.cancel());
    controller.dispose();
    await tester.pump();
  });
  testWidgets(
    'preflight timeout is unsent; POST timeout has uncertain outcome and is never retried',
    (tester) async {
      final api = FakeRemoteApi();
      final controller = remoteController(api);
      final listener = controller.changes.listen((_) {});
      await tester.pump();
      final first = await controller.createIntent(
        controller.state.targets.single,
        itemId,
      );
      api.itemError = TimeoutException('private-endpoint');
      await expectLater(
        controller.play(first),
        throwsA(failure(RemotePlaybackFailure.timeout)),
      );
      expect(api.commands, isEmpty);
      expect(controller.state.outcomeUnknown, isFalse);
      api.itemError = null;
      await controller.refresh();
      final second = await controller.createIntent(
        controller.state.targets.single,
        itemId,
      );
      api.playError = TimeoutException('private-endpoint');
      await expectLater(
        controller.play(second),
        throwsA(failure(RemotePlaybackFailure.timeout, uncertain: true)),
      );
      expect(controller.state.outcomeUnknown, isTrue);
      expect(controller.state.receipt, isNull);
      await tester.pump(const Duration(minutes: 2));
      expect(api.commands, hasLength(1));
      unawaited(listener.cancel());
      controller.dispose();
      await tester.pump();
    },
  );
  for (final status in [401, 403]) {
    testWidgets(
      'POST$status is an explicit rejection, not uncertain delivery',
      (tester) async {
        final api = FakeRemoteApi();
        final controller = remoteController(api);
        final listener = controller.changes.listen((_) {});
        await tester.pump();
        final intent = await controller.createIntent(
          controller.state.targets.single,
          itemId,
        );
        api.playError = MediaApiException('private-detail', statusCode: status);
        await expectLater(
          controller.play(intent),
          throwsA(
            failure(
              status == 401
                  ? RemotePlaybackFailure.authentication
                  : RemotePlaybackFailure.permission,
            ),
          ),
        );
        expect(controller.state.outcomeUnknown, isFalse);
        expect(api.commands, hasLength(1));
        unawaited(listener.cancel());
        controller.dispose();
        await tester.pump();
      },
    );
  }
  for (final evidence in [
    (itemId, false, true),
    (otherItemId, false, false),
    (itemId, true, false),
    (itemId, null, false),
  ]) {
    testWidgets(
      'accepted remains distinct from exact receiver playback evidence $evidence',
      (tester) async {
        final api = FakeRemoteApi();
        final controller = remoteController(api);
        final listener = controller.changes.listen((_) {});
        await tester.pump();
        final intent = await controller.createIntent(
          controller.state.targets.single,
          itemId,
        );
        final receipt = await controller.play(intent);
        expect(receipt.status, RemotePlaybackReceiptStatus.accepted);
        api.targets = [target(nowPlaying: evidence.$1, paused: evidence.$2)];
        for (final seconds in [1, 2, 3]) {
          await tester.pump(Duration(seconds: seconds));
        }
        expect(
          controller.state.receipt?.status,
          evidence.$3
              ? RemotePlaybackReceiptStatus.observed
              : RemotePlaybackReceiptStatus.unconfirmed,
        );
        expect(api.reads, evidence.$3 ? 3 : 5);
        await tester.pump(const Duration(minutes: 2));
        expect(api.commands, hasLength(1));
        expect(api.reads, evidence.$3 ? 3 : 5);
        unawaited(listener.cancel());
        controller.dispose();
        await tester.pump();
      },
    );
  }
  testWidgets(
    'unchanged same-item snapshot is not new playback evidence; explicit refresh can observe a later check-in',
    (tester) async {
      final api = FakeRemoteApi()..targets = [target(nowPlaying: itemId)];
      final controller = remoteController(api);
      final listener = controller.changes.listen((_) {});
      await tester.pump();
      final intent = await controller.createIntent(
        controller.state.targets.single,
        itemId,
      );
      await controller.play(intent);
      for (final seconds in [1, 2, 3]) {
        await tester.pump(Duration(seconds: seconds));
      }
      expect(
        controller.state.receipt?.status,
        RemotePlaybackReceiptStatus.unconfirmed,
      );
      final json = targetJson(nowPlaying: itemId)
        ..['LastPlaybackCheckIn'] = remoteNow
            .add(const Duration(seconds: 8))
            .toIso8601String();
      api.targets = parseRemotePlaybackTargets([json]);
      await controller.refresh();
      expect(
        controller.state.receipt?.status,
        RemotePlaybackReceiptStatus.observed,
      );
      expect(api.commands, hasLength(1));
      unawaited(listener.cancel());
      controller.dispose();
      await tester.pump();
    },
  );
  testWidgets(
    'timeout waiting for actual POST completion never retries and late completion creates no receipt',
    (tester) async {
      final api = FakeRemoteApi();
      final controller = remoteController(api);
      final listener = controller.changes.listen((_) {});
      await tester.pump();
      final intent = await controller.createIntent(
        controller.state.targets.single,
        itemId,
      );
      api.playGate = Completer<void>();
      final pending = expectLater(
        controller.play(intent),
        throwsA(failure(RemotePlaybackFailure.timeout, uncertain: true)),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 15));
      await pending;
      expect(api.commands, hasLength(1));
      expect(controller.state.receipt, isNull);
      api.playGate!.complete();
      await tester.pump();
      expect(controller.state.receipt, isNull);
      expect(controller.state.outcomeUnknown, isTrue);
      await tester.pump(const Duration(minutes: 1));
      expect(api.commands, hasLength(1));
      unawaited(listener.cancel());
      controller.dispose();
      await tester.pump();
    },
  );
  testWidgets(
    'intent expires during preflight and unsupported resume position never sends',
    (tester) async {
      var now = remoteNow;
      final api = FakeRemoteApi();
      final controller = remoteController(api, now: () => now);
      final listener = controller.changes.listen((_) {});
      await tester.pump();
      await expectLater(
        controller.createIntent(
          controller.state.targets.single,
          itemId,
          startPosition: const Duration(hours: 2),
        ),
        throwsA(failure(RemotePlaybackFailure.unsupportedItem)),
      );
      final intent = await controller.createIntent(
        controller.state.targets.single,
        itemId,
      );
      api.targetGate = Completer<void>();
      final pending = expectLater(
        controller.play(intent),
        throwsA(failure(RemotePlaybackFailure.expiredIntent)),
      );
      await tester.pump();
      now = now.add(const Duration(seconds: 31));
      api.targetGate!.complete();
      await pending;
      expect(api.commands, isEmpty);
      unawaited(listener.cancel());
      controller.dispose();
      await tester.pump();
    },
  );
  testWidgets(
    'failed observation preserves accepted command as unconfirmed and clears receiver evidence',
    (tester) async {
      final api = FakeRemoteApi();
      final controller = remoteController(api);
      final listener = controller.changes.listen((_) {});
      await tester.pump();
      final intent = await controller.createIntent(
        controller.state.targets.single,
        itemId,
      );
      await controller.play(intent);
      api.targetError = MediaApiException('private-detail', statusCode: 403);
      await tester.pump(const Duration(seconds: 1));
      expect(
        controller.state.receipt?.status,
        RemotePlaybackReceiptStatus.unconfirmed,
      );
      expect(controller.state.failure, RemotePlaybackFailure.permission);
      expect(controller.state.targets, isEmpty);
      expect(
        controller.state.outcomeUnknown,
        isFalse,
        reason: '204 was received even though later observation failed',
      );
      await tester.pump(const Duration(minutes: 1));
      expect(api.commands, hasLength(1));
      unawaited(listener.cancel());
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'hidden and resumed pending discovery re-reads once and never exposes late old observation',
    (tester) async {
      final api = FakeRemoteApi()..targetGate = Completer<void>();
      final controller = remoteController(api);
      final listener = controller.changes.listen((_) {});
      await tester.pump();
      controller.setVisible(false);
      controller.setVisible(true);
      api.targetGate!.complete();
      await tester.pump();
      expect(api.reads, 2);
      expect(controller.state.targets, hasLength(1));
      final intent = await controller.createIntent(
        controller.state.targets.single,
        itemId,
      );
      await controller.play(intent);
      api.targetGate = Completer<void>();
      api.targets = [target(nowPlaying: itemId)];
      await tester.pump(const Duration(seconds: 1));
      controller.setForeground(false);
      api.targetGate!.complete();
      await tester.pump();
      expect(controller.state.receipt, isNull);
      expect(controller.state.targets, isEmpty);
      final reads = api.reads;
      await tester.pump(const Duration(minutes: 2));
      expect(api.reads, reads);
      unawaited(listener.cancel());
      controller.dispose();
      await tester.pump();
    },
  );
}
