import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/idle_prevention.dart';

void main() {
  test('independent video leases release separately and disposed owners cannot revive', () {
    final c = IdlePreventionController();
    final a = Object(), b = Object();
    var notifications = 0;
    c.addListener(() => notifications++);
    c.set(a, true);
    c.set(b, true);
    c.set(a, false);
    expect(c.prevented, true);
    expect(notifications, 1);
    c.set(b, false);
    expect(c.prevented, false);
    expect(notifications, 2);
    c.dispose();
    c.set(a, true);
    expect(c.prevented, false);
  });
  testWidgets(
    'video lease tracks actual active flag route foreground visibility and disposal',
    (tester) async {
      final c = ProviderContainer();
      final nav = GlobalKey<NavigatorState>();
      final active = ValueNotifier(true), visible = ValueNotifier(true);
      addTearDown(c.dispose);
      addTearDown(active.dispose);
      addTearDown(visible.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: CupertinoApp(
            navigatorKey: nav,
            home: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (context, on, _) => TickerMode(
                enabled: on,
                child: ValueListenableBuilder<bool>(
                  valueListenable: active,
                  builder: (context, playing, _) => PreventAmbientDisplay(
                    active: playing,
                    child: const Text('Video'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final controller = c.read(idlePreventionProvider);
      expect(controller.prevented, true);
      final context = tester.element(find.text('Video'));
      unawaited(
        nav.currentState!.push(
          CupertinoDialogRoute<void>(
            context: context,
            builder: (_) =>
                const CupertinoAlertDialog(title: Text('Other route')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.prevented, false);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(controller.prevented, true);
      active.value = false;
      await tester.pump();
      expect(controller.prevented, false);
      active.value = true;
      visible.value = false;
      await tester.pump();
      expect(controller.prevented, false);
      visible.value = true;
      await tester.pump();
      expect(controller.prevented, true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(controller.prevented, false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(controller.prevented, true);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(controller.prevented, false);
    },
  );
}
