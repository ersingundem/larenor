import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/music/core/data/core_music_targets_api.dart';
import 'package:larenor/features/media/music/core/data/core_music_targets_controller.dart';
import 'package:larenor/features/media/music/core/domain/core_music_target_models.dart';
import 'package:larenor/features/media/music/core/presentation/core_music_targets_panel.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'core_music_targets_test.dart' show discoveryFixture;

class FixtureApi implements CoreMusicTargetsApi {
  @override
  Future<CoreMusicTargetInventory> read({
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const CoreMusicTargetsException('stale');
    return CoreMusicTargetInventory.fromJson(discoveryFixture()['inventory']);
  }
}

class DelayedFixtureApi implements CoreMusicTargetsApi {
  final result = Completer<CoreMusicTargetInventory>();

  @override
  Future<CoreMusicTargetInventory> read({required bool Function() isCurrent}) =>
      result.future;
}

void main() {
  test('account lifecycle retirement drops a late inventory', () async {
    final lifecycle = ValueNotifier(0);
    var authorized = true;
    final api = DelayedFixtureApi();
    final controller = CoreMusicTargetsController(
      api: api,
      lifecycle: lifecycle,
      authorized: () => authorized,
    );
    controller.setVisible(true);
    expect(controller.busy, isTrue);
    authorized = false;
    lifecycle.value++;
    api.result.complete(
      CoreMusicTargetInventory.fromJson(discoveryFixture()['inventory']),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.inventory, isNull);
    expect(controller.selectedTargetId, isNull);
    expect(controller.busy, isFalse);
    controller.dispose();
    lifecycle.dispose();
  });

  for (final fixture in [
    (size: const Size(600, 1000), scale: 2.0),
    (size: const Size(1280, 800), scale: 1.0),
  ]) {
    testWidgets(
      'target selector adapts at ${fixture.size.width} and ${fixture.scale}x',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = fixture.size;
        addTearDown(tester.view.reset);
        final lifecycle = ValueNotifier(0);
        final controller = CoreMusicTargetsController(
          api: FixtureApi(),
          lifecycle: lifecycle,
          authorized: () => true,
        );
        addTearDown(() {
          controller.dispose();
          lifecycle.dispose();
        });
        await tester.pumpWidget(
          CupertinoApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(fixture.scale)),
              child: child!,
            ),
            home: CupertinoPageScaffold(
              child: CoreMusicTargetsPanel(controller: controller),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Living HomePod'), findsOneWidget);
        expect(find.text('Synthetic Song'), findsOneWidget);
        expect(find.text('4 items • 0:37 / 4:01'), findsOneWidget);
        final button = find.byKey(
          const ValueKey('core-music-target-homepod-living'),
        );
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        await tester.tap(button);
        await tester.pump();
        expect(controller.selectedTargetId, 'homepod-living');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'DeX keyboard selects the focused output and semantics name state',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.reset);
      final lifecycle = ValueNotifier(0);
      final controller = CoreMusicTargetsController(
        api: FixtureApi(),
        lifecycle: lifecycle,
        authorized: () => true,
      );
      addTearDown(() {
        controller.dispose();
        lifecycle.dispose();
      });
      await tester.pumpWidget(
        CupertinoApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CupertinoPageScaffold(
            child: CoreMusicTargetsPanel(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(controller.selectedTargetId, 'homepod-living');
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey('core-music-target-homepod-living')),
        ),
        matchesSemantics(
          label: 'Living HomePod, HomePod, Paused, Synthetic Song',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          hasEnabledState: true,
          isEnabled: true,
        ),
      );
    },
  );
}
