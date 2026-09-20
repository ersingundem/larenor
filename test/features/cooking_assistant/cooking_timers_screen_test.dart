import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/cooking_assistant/data/cooking_timers_controller.dart';
import 'package:larenor/features/cooking_assistant/domain/cooking_timer.dart';
import 'package:larenor/features/cooking_assistant/presentation/cooking_timers_screen.dart';

final class _Clock implements CookingTimerClock {
  @override
  Duration get monotonicNow => Duration.zero;
  @override
  Duration get wallNow => Duration.zero;
}

final class _Store implements CookingTimerStore {
  CookingTimer? value;
  @override
  Future<List<CookingTimer>> read(
    String accountId,
    String recipeSessionId,
  ) async => value == null ? [] : [value!];
  @override
  Future<void> write(
    CookingTimer timer, {
    required int expectedRevision,
  }) async => value = timer;
}

final class _Notifications implements CookingTimerNotifications {
  @override
  Future<void> finished({
    required String idempotencyKey,
    required String label,
  }) async {}
}

void main() {
  testWidgets(
    '600/1200 rotation keeps one controller and accessible 48dp actions',
    (tester) async {
      final store = _Store();
      final controller = CookingTimersController(
        store: store,
        notifications: _Notifications(),
        clock: _Clock(),
        authority: const CookingTimerAuthority(
          accountId: 'account-a',
          recipeSessionId: 'recipe-session',
          epoch: 1,
        ),
        isCurrent: () => true,
      );
      await controller.restore();
      await controller.start(
        label: 'Oven',
        duration: const Duration(minutes: 5),
      );
      for (final width in const [600.0, 1200.0, 600.0]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 900),
                textScaler: const TextScaler.linear(2),
              ),
              child: CookingTimersScreen(
                controller: controller,
                strings: CookingTimerStrings.en,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Oven'), findsOneWidget);
        final acknowledge = find.byKey(const Key('timer-acknowledge'));
        expect(tester.getSize(acknowledge).height, greaterThanOrEqualTo(48));
        expect(
          find.bySemanticsLabel(CookingTimerStrings.en.acknowledge),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
      expect(controller.restoreCount, 1);
      addTearDown(tester.view.reset);
    },
  );

  testWidgets('Turkish copy remains visible at 2x', (tester) async {
    final controller = CookingTimersController(
      store: _Store(),
      notifications: _Notifications(),
      clock: _Clock(),
      authority: const CookingTimerAuthority(
        accountId: 'account-a',
        recipeSessionId: 'recipe-session',
        epoch: 1,
      ),
      isCurrent: () => true,
    );
    await controller.restore();
    await controller.start(
      label: 'Fırın',
      duration: const Duration(minutes: 5),
    );
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(600, 900),
            textScaler: TextScaler.linear(2),
          ),
          child: CookingTimersScreen(
            controller: controller,
            strings: CookingTimerStrings.tr,
          ),
        ),
      ),
    );
    expect(find.text(CookingTimerStrings.tr.title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
