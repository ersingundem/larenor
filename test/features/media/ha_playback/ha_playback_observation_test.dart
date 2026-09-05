import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/ha_playback/data/ha_playback_controller.dart';
import 'package:larenor/features/media/ha_playback/domain/ha_playback_models.dart';

import 'ha_playback_fixture.dart';

void main() {
  for (final baselinePlaying in [false, true]) {
    test(
      'observation requires changed exact source and never promotes already-playing item ($baselinePlaying)',
      () {
        fakeAsync((async) {
          final api = FakeHaPlaybackApi();
          if (baselinePlaying) {
            api.currentInventory = inventory(
              state: stateRaw(state: 'playing', contentId: mediaSource),
            );
          }
          final controller = HaPlaybackController(
            api: api,
            isCurrent: () => true,
            now: () => playbackNow.add(async.elapsed),
          );
          final sub = controller.changes.listen((_) {});
          async.flushMicrotasks();
          HaPlaybackIntent? prepared;
          controller
              .createIntent(
                controller.state.page!.children.single,
                controller.state.inventory!.targets.single,
              )
              .then((value) => prepared = value);
          async.flushMicrotasks();
          controller.play(prepared!);
          async.flushMicrotasks();
          expect(
            controller.state.receipt!.status,
            HaPlaybackReceiptStatus.accepted,
          );
          api.currentInventory = inventory(
            state: stateRaw(
              state: 'playing',
              contentId: mediaSource,
              updated: playbackNow.add(const Duration(seconds: 1)),
            ),
          );
          async.elapse(const Duration(seconds: 6));
          async.flushMicrotasks();
          expect(
            controller.state.receipt!.status,
            baselinePlaying
                ? HaPlaybackReceiptStatus.unconfirmed
                : HaPlaybackReceiptStatus.observed,
          );
          expect(api.commands, hasLength(1));
          sub.cancel();
          controller.dispose();
          api.dispose();
          async.flushMicrotasks();
          expect(async.pendingTimers, isEmpty);
        });
      },
    );
  }
  test(
    'background cancels follow-up timers and never polls hidden targets',
    () {
      fakeAsync((async) {
        final api = FakeHaPlaybackApi();
        final controller = HaPlaybackController(
          api: api,
          isCurrent: () => true,
          now: () => playbackNow,
        );
        final sub = controller.changes.listen((_) {});
        async.flushMicrotasks();
        HaPlaybackIntent? prepared;
        controller
            .createIntent(
              controller.state.page!.children.single,
              controller.state.inventory!.targets.single,
            )
            .then((value) => prepared = value);
        async.flushMicrotasks();
        controller.play(prepared!);
        async.flushMicrotasks();
        final reads = api.inventoryReads;
        controller.setForeground(false);
        async.elapse(const Duration(minutes: 5));
        expect(api.inventoryReads, reads);
        expect(controller.state.receipt, isNull);
        sub.cancel();
        controller.dispose();
        api.dispose();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    },
  );
}
