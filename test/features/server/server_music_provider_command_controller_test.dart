import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/music_provider_commands/data/server_music_provider_commands_controller.dart';

import 'server_music_provider_command_test_support.dart';

ServerMusicProviderCommandsController createController(
  ProviderCommandFixture fixture, {
  DateTime Function()? now,
}) => ServerMusicProviderCommandsController(
  fixture.account,
  installationId: 'b' * 32,
  installationRevision: 4,
  providerSetupId: 'c' * 32,
  providerRevision: 3,
  providerDomain: 'spotify',
  requestId: () => 'f' * 32,
  now: now,
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

  test(
    'review and confirm are single flight and require two user actions',
    () async {
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
      final previewBody =
          jsonDecode(fixture.providerPosts.single.body) as Map<String, dynamic>;
      expect(previewBody.keys.toSet(), {
        'requestId',
        'installationId',
        'expectedInstallationRevision',
        'providerSetupId',
        'expectedProviderRevision',
        'providerDomain',
        'command',
        'settings',
      });
      expect(previewBody['settings'], isEmpty);
      expect(fixture.providerPosts.single.body, isNot(contains('token')));

      fixture.confirmResponse = Completer();
      final firstConfirm = controller.confirm(current: () => true);
      await flush();
      final duplicateConfirm = controller.confirm(current: () => true);
      await flush();
      expect(fixture.providerPosts, hasLength(2));
      fixture.confirmResponse!.complete(
        fixture.json({
          'command': providerCommandJson(requestId: 'f' * 32),
        }, 201),
      );
      await Future.wait([firstConfirm, duplicateConfirm]);
      expect(controller.command, isNotNull);
      expect(fixture.providerPosts, hasLength(2));
      final confirmBody = jsonDecode(fixture.providerPosts.last.body) as Map;
      expect(confirmBody.keys.toSet(), {
        'requestId',
        'previewId',
        'expectedPreviewRevision',
        'planHash',
      });
      expect(fixture.providerPosts.last.body, isNot(contains('token')));
    },
  );

  test('strict API response rejects secret-shaped additions', () async {
    final fixture = ProviderCommandFixture();
    await fixture.account.initialize();
    final controller = createController(fixture);
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    fixture.previewResponse = Completer();

    final pending = controller.review('disable', current: () => true);
    await flush();
    fixture.previewResponse!.complete(
      fixture.json({
        'preview': {...providerCommandPreviewJson(), 'token': 'synthetic'},
      }, 201),
    );
    await pending;

    expect(controller.preview, isNull);
    expect(controller.failure, 'invalid_response');
    expect(controller.failure, isNot(contains('synthetic')));
    expect(fixture.providerPosts, hasLength(1));
  });

  for (final timing in ['expired', 'future']) {
    test('$timing preview response never becomes confirm authority', () async {
      final fixture = ProviderCommandFixture();
      await fixture.account.initialize();
      final controller = createController(
        fixture,
        now: () => DateTime.utc(2026, 9, 10, 10, 5),
      );
      addTearDown(controller.dispose);
      addTearDown(fixture.account.dispose);
      fixture.previewResponse = Completer();

      final pending = controller.review('disable', current: () => true);
      await flush();
      final preview = providerCommandPreviewJson();
      if (timing == 'expired') {
        preview['createdAt'] = '2026-09-10T09:50:00.000Z';
        preview['expiresAt'] = '2026-09-10T10:00:00.000Z';
      } else {
        preview['createdAt'] = '2026-09-10T10:06:00.000Z';
        preview['expiresAt'] = '2026-09-10T10:16:00.000Z';
      }
      fixture.previewResponse!.complete(
        fixture.json({'preview': preview}, 201),
      );
      await pending;

      expect(controller.preview, isNull);
      expect(controller.command, isNull);
      expect(controller.failure, 'music_provider_preview_invalid');
      expect(fixture.providerPosts, hasLength(1));
    });
  }

  test(
    'confirm rechecks expiry after session acquisition before POST',
    () async {
      final fixture = ProviderCommandFixture();
      await fixture.account.initialize();
      final instant = DateTime.utc(2026, 9, 10, 10, 5);
      var expireDuringConfirm = false;
      var confirmClockReads = 0;
      final controller = createController(
        fixture,
        now: () {
          if (!expireDuringConfirm) return instant;
          confirmClockReads++;
          return confirmClockReads == 1
              ? DateTime.utc(2026, 9, 10, 10, 9, 59)
              : DateTime.utc(2026, 9, 10, 10, 10);
        },
      );
      addTearDown(controller.dispose);
      addTearDown(fixture.account.dispose);
      fixture.previewResponse = Completer();
      final review = controller.review('disable', current: () => true);
      await flush();
      fixture.previewResponse!.complete(
        fixture.json({
          'preview': providerCommandPreviewJson(
            createdAt: DateTime.utc(2026, 9, 10, 10),
          ),
        }, 201),
      );
      await review;
      expect(controller.preview, isNotNull);

      expireDuringConfirm = true;
      await controller.confirm(current: () => true);

      expect(confirmClockReads, greaterThanOrEqualTo(2));
      expect(controller.preview, isNull);
      expect(controller.command, isNull);
      expect(controller.failure, 'music_provider_preview_invalid');
      expect(fixture.providerPosts, hasLength(1));
    },
  );

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
