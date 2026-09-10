import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/music_provider_commands/data/server_music_provider_commands_controller.dart';

import 'server_music_provider_command_test_support.dart';

ServerMusicProviderCommandsController createController(
  ProviderCommandFixture fixture,
) => ServerMusicProviderCommandsController(
  fixture.account,
  installationId: 'b' * 32,
  installationRevision: 4,
  providerSetupId: 'c' * 32,
  providerRevision: 3,
  providerDomain: 'spotify',
  requestId: () => 'f' * 32,
);

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('member cannot create a provider command preview', () async {
    final fixture = ProviderCommandFixture(role: ServerRole.member);
    await fixture.account.initialize();
    final controller = createController(fixture);
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);

    await controller.review('disable', current: () => true);

    expect(fixture.providerPosts, isEmpty);
    expect(controller.preview, isNull);
    expect(controller.failure, isNull);
  });

  test('review and confirm are single flight and require two user actions', () async {
    final fixture = ProviderCommandFixture();
    await fixture.account.initialize();
    final controller = createController(fixture);
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    fixture.previewResponse = Completer();

    final firstReview = controller.review('disable', current: () => true);
    await flush();
    final duplicateReview = controller.review('disable', current: () => true);
    await flush();
    expect(fixture.providerPosts, hasLength(1));
    expect(controller.busy, isTrue);
    fixture.previewResponse!.complete(
      fixture.json({'preview': providerCommandPreviewJson()}, 201),
    );
    await Future.wait([firstReview, duplicateReview]);
    expect(controller.preview, isNotNull);
    expect(controller.command, isNull);
    expect(fixture.providerPosts, hasLength(1));

    fixture.confirmResponse = Completer();
    final firstConfirm = controller.confirm(current: () => true);
    await flush();
    final duplicateConfirm = controller.confirm(current: () => true);
    await flush();
    expect(fixture.providerPosts, hasLength(2));
    fixture.confirmResponse!.complete(
      fixture.json({'command': providerCommandJson(requestId: 'f' * 32)}, 201),
    );
    await Future.wait([firstConfirm, duplicateConfirm]);
    expect(controller.command, isNotNull);
    expect(fixture.providerPosts, hasLength(2));
  });

  for (final boundary in ['pin', 'background', 'route', 'account']) {
    test('$boundary change discards a late preview without retry', () async {
      final fixture = ProviderCommandFixture();
      await fixture.account.initialize();
      final controller = createController(fixture);
      addTearDown(controller.dispose);
      addTearDown(fixture.account.dispose);
      fixture.previewResponse = Completer();
      var current = true;

      final pending = controller.review('disable', current: () => current);
      await flush();
      expect(fixture.providerPosts, hasLength(1));
      if (boundary == 'account') {
        await fixture.account.signOut();
      } else {
        current = false;
        if (boundary != 'route') controller.invalidate();
      }
      fixture.previewResponse!.complete(
        fixture.json({'preview': providerCommandPreviewJson()}, 201),
      );
      await pending;

      expect(controller.preview, isNull);
      expect(controller.command, isNull);
      expect(controller.failure, isNull);
      expect(fixture.providerPosts, hasLength(1));
    });
  }

  test('invalidated late confirm is discarded without replay', () async {
    final fixture = ProviderCommandFixture();
    await fixture.account.initialize();
    final controller = createController(fixture);
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    await controller.review('disable', current: () => true);
    fixture.confirmResponse = Completer();

    final pending = controller.confirm(current: () => true);
    await flush();
    expect(fixture.providerPosts, hasLength(2));
    controller.invalidate();
    fixture.confirmResponse!.complete(
      fixture.json({'command': providerCommandJson(requestId: 'f' * 32)}, 201),
    );
    await pending;

    expect(controller.preview, isNull);
    expect(controller.command, isNull);
    expect(controller.failure, isNull);
    expect(fixture.providerPosts, hasLength(2));
  });
}
