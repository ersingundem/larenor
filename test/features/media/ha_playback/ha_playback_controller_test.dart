import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/ha_playback/data/ha_playback_controller.dart';
import 'package:larenor/features/media/ha_playback/domain/ha_playback_models.dart';

import 'ha_playback_fixture.dart';

Matcher failure(HaPlaybackFailure value) => throwsA(
  isA<HaPlaybackException>().having((e) => e.failure, 'failure', value),
);
void main() {
  late FakeHaPlaybackApi api;
  late HaPlaybackController controller;
  late StreamSubscription<HaPlaybackSnapshot> listener;
  late DateTime now;
  var current = true;
  setUp(() async {
    now = playbackNow;
    current = true;
    api = FakeHaPlaybackApi();
    controller = HaPlaybackController(
      api: api,
      isCurrent: () => current,
      now: () => now,
    );
    listener = controller.changes.listen((_) {});
    await drain();
  });
  tearDown(() async {
    await listener.cancel();
    controller.dispose();
    api.dispose();
  });
  Future<HaPlaybackIntent> intent() => controller.createIntent(
    controller.state.page!.children.single,
    controller.state.inventory!.targets.single,
  );
  test('one explicit confirmation sends one exact entity/source/MIME and reports accepted', () async {
    final prepared = await intent();
    final receipt = await controller.play(prepared);
    expect(receipt.status, HaPlaybackReceiptStatus.accepted);
    expect(api.commands, hasLength(1));
    expect(api.commands.single.entityId, 'media_player.living');
    expect(api.commands.single.source.mediaType, 'audio/mpeg');
    await expectLater(
      controller.play(prepared),
      failure(HaPlaybackFailure.invalidIntent),
    );
    expect(api.commands, hasLength(1));
  });
  test('source changed since named confirmation prevents command', () async {
    final prepared = await intent();
    api.pages['media-source://'] = parseHaMediaBrowse(
      browseRaw(children: [browseNode(title: 'Replacement')]),
      playbackNow,
    );
    await expectLater(
      controller.play(prepared),
      failure(HaPlaybackFailure.sourceChanged),
    );
    expect(api.commands, isEmpty);
  });
  test(
    'registry identity/capability/service change fails fresh preflight',
    () async {
      for (final replacement in [
        inventory(registry: registryRaw(registry: 'replacement')),
        inventory(state: stateRaw(features: 0)),
        inventory(services: {}),
      ]) {
        final prepared = await intent();
        api.currentInventory = replacement;
        await expectLater(
          controller.play(prepared),
          failure(HaPlaybackFailure.unsupportedTarget),
        );
        api.currentInventory = inventory();
        await controller.refresh();
      }
      expect(api.commands, isEmpty);
    },
  );
  test('two taps while fresh validation blocked share no mutations', () async {
    final prepared = await intent();
    final gate = Completer<void>();
    api.browseGate = () => gate.future;
    final pending = controller.play(prepared);
    await expectLater(
      controller.play(prepared),
      failure(HaPlaybackFailure.busy),
    );
    gate.complete();
    await pending;
    expect(api.commands, hasLength(1));
  });
  test('expired and canceled confirmations cannot dispatch', () async {
    final prepared = await intent();
    now = now.add(const Duration(seconds: 30));
    await expectLater(
      controller.play(prepared),
      failure(HaPlaybackFailure.expiredIntent),
    );
    final canceled = await intent();
    controller.cancelIntent();
    await expectLater(
      controller.play(canceled),
      failure(HaPlaybackFailure.invalidIntent),
    );
    expect(api.commands, isEmpty);
  });
  for (final reason in ['account', 'background', 'hidden', 'connection']) {
    test(
      '$reason change during preflight cancels and drops old evidence',
      () async {
        final prepared = await intent();
        final gate = Completer<void>();
        api.browseGate = () => gate.future;
        final pending = controller.play(prepared);
        final failed = expectLater(
          pending,
          failure(HaPlaybackFailure.invalidIntent),
        );
        if (reason == 'account') current = false;
        if (reason == 'background') controller.setForeground(false);
        if (reason == 'hidden') controller.setVisible(false);
        if (reason == 'connection') api.connections.add(false);
        await drain();
        gate.complete();
        await failed;
        expect(api.commands, isEmpty);
      },
    );
  }
  test(
    'background after preflight but before actual socket dispatch also cancels',
    () async {
      final prepared = await intent();
      final gate = Completer<void>();
      api.playGate = () => gate.future;
      final pending = controller.play(prepared);
      final failed = expectLater(
        pending,
        failure(HaPlaybackFailure.invalidIntent),
      );
      await drain();
      controller.setForeground(false);
      gate.complete();
      await failed;
      expect(api.commands, isEmpty);
    },
  );
  test('lost response is uncertain and never automatically replayed', () async {
    final prepared = await intent();
    api.playError = TimeoutException('secret backend content');
    await expectLater(
      controller.play(prepared),
      throwsA(
        isA<HaPlaybackException>().having(
          (e) => e.outcomeUnknown,
          'unknown',
          true,
        ),
      ),
    );
    expect(controller.state.outcomeUnknown, isTrue);
    expect(api.commands, hasLength(1));
    await expectLater(
      controller.play(prepared),
      failure(HaPlaybackFailure.invalidIntent),
    );
    expect(api.commands, hasLength(1));
  });
  test('refresh failure clears retained selectable results rather than empty success', () async {
    api.inventoryError = const HaPlaybackException(
      HaPlaybackFailure.permission,
    );
    await controller.refresh();
    expect(controller.state.page, isNull);
    expect(controller.state.inventory, isNull);
    expect(controller.state.failure, HaPlaybackFailure.permission);
    expect(api.commands, isEmpty);
  });
  test('foreign node and source owner are rejected', () async {
    const unknown = HaMediaNode(
      id: 'media-source://other',
      title: 'Other',
      mediaType: 'directory',
      mediaClass: 'directory',
      canPlay: false,
      canExpand: true,
    );
    expect(
      () => controller.browse(unknown),
      failure(HaPlaybackFailure.invalidIntent),
    );
    final other = HaPlaybackController(
      api: FakeHaPlaybackApi(),
      isCurrent: () => true,
      now: () => now,
    );
    final sub = other.changes.listen((_) {});
    await drain();
    final otherIntent = await other.createIntent(
      other.state.page!.children.single,
      other.state.inventory!.targets.single,
    );
    await expectLater(
      controller.play(otherIntent),
      failure(HaPlaybackFailure.invalidIntent),
    );
    await sub.cancel();
    other.dispose();
  });
  test('browse into known source and back uses remembered ancestry; refresh invalidates intent', () async {
    final folder = HaMediaNode(
      id: 'media-source://media_source',
      title: 'Local',
      mediaType: 'directory',
      mediaClass: 'directory',
      canPlay: false,
      canExpand: true,
    );
    api.pages['media-source://'] = parseHaMediaBrowse(
      browseRaw(
        children: [
          browseNode(
            id: folder.id,
            title: folder.title,
            type: folder.mediaType,
            play: false,
            expand: true,
          ),
        ],
      ),
      playbackNow,
    );
    api.pages[folder.id] = parseHaMediaBrowse(
      browseRaw(parent: folder.id),
      playbackNow,
    );
    await controller.refresh();
    final root = controller.state.page!.parent;
    await controller.browse(controller.state.page!.children.single);
    final prepared = await intent();
    await controller.browse(root);
    expect(controller.state.page!.parent.id, 'media-source://');
    await expectLater(
      controller.play(prepared),
      failure(HaPlaybackFailure.invalidIntent),
    );
  });
  test(
    'pending read resumed before completion restarts once without overlap',
    () async {
      final gate = Completer<void>();
      var activeReads = 0, maxActive = 0;
      api.inventoryGate = () async {
        activeReads++;
        if (activeReads > maxActive) maxActive = activeReads;
        await gate.future;
        activeReads--;
      };
      final pending = controller.refresh();
      controller.setForeground(false);
      controller.setForeground(true);
      gate.complete();
      await pending;
      await drain();
      expect(maxActive, 1);
      expect(controller.state.page, isNotNull);
    },
  );
}
