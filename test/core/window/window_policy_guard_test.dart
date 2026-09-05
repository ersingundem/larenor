// Retained AsyncValue states reproduce Riverpod reload/error behavior.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/immersive_mode_guard.dart';
import 'package:larenor/core/window/window_policy_bridge.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/settings/providers/window_profile_provider.dart';

class _Profile extends WindowProfileNotifier {
  @override
  Future<WindowProfile> build() async => WindowProfile.panel;
  void show(AsyncValue<WindowProfile> value) => state = value;
}

class _Bridge extends WindowPolicyBridge {
  final writes = <WindowProfile>[];
  Completer<void>? waiting;
  var active = 0;
  var maximum = 0;
  @override
  Future<WindowPolicySnapshot> setProfile(WindowProfile profile) async {
    writes.add(profile);
    active++;
    if (active > maximum) maximum = active;
    final gate = waiting;
    if (gate != null) {
      waiting = null;
      await gate.future;
    }
    active--;
    return const WindowPolicySnapshot(supported: true);
  }
}

void main() {
  testWidgets(
    'stored panel loads safely and retained loading/error restores adaptive',
    (tester) async {
      final bridge = _Bridge();
      final container = ProviderContainer(
        overrides: [
          windowPolicyBridgeProvider.overrideWithValue(bridge),
          windowProfileProvider.overrideWith(_Profile.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ImmersiveModeGuard(child: SizedBox()),
        ),
      );
      await tester.pump();
      expect(bridge.writes, [WindowProfile.adaptive, WindowProfile.panel]);
      final notifier =
          container.read(windowProfileProvider.notifier) as _Profile;
      notifier.show(
        const AsyncLoading<WindowProfile>().copyWithPrevious(
          const AsyncData(WindowProfile.panel),
        ),
      );
      await tester.pump();
      expect(bridge.writes.last, WindowProfile.adaptive);
      notifier.show(
        AsyncError<WindowProfile>(
          StateError('fixture-private'),
          StackTrace.empty,
        ).copyWithPrevious(const AsyncData(WindowProfile.panel)),
      );
      await tester.pump();
      expect(
        bridge.writes.where((v) => v == WindowProfile.panel),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'queued changes serialize and disposal cannot leave late panel applied',
    (tester) async {
      final gate = Completer<void>();
      final bridge = _Bridge()..waiting = gate;
      final container = ProviderContainer(
        overrides: [
          windowPolicyBridgeProvider.overrideWithValue(bridge),
          windowProfileProvider.overrideWith(_Profile.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ImmersiveModeGuard(child: SizedBox()),
        ),
      );
      await tester.pump();
      expect(bridge.writes, [WindowProfile.adaptive]);
      gate.complete();
      await tester.pump();
      expect(bridge.writes.last, WindowProfile.panel);
      final next = Completer<void>();
      bridge.waiting = next;
      final notifier =
          container.read(windowProfileProvider.notifier) as _Profile;
      notifier.show(const AsyncData(WindowProfile.adaptive));
      await tester.pump();
      notifier.show(const AsyncData(WindowProfile.panel));
      await tester.pumpWidget(const SizedBox());
      next.complete();
      await tester.pump();
      expect(bridge.writes.last, WindowProfile.adaptive);
      expect(bridge.maximum, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late disposed wrapper cannot reset its replacement profile', (
    tester,
  ) async {
    final bridge = _Bridge();
    final container = ProviderContainer(
      overrides: [
        windowPolicyBridgeProvider.overrideWithValue(bridge),
        windowProfileProvider.overrideWith(_Profile.new),
      ],
    );
    addTearDown(container.dispose);
    Widget wrapper(Key key) => UncontrolledProviderScope(
      container: container,
      child: ImmersiveModeGuard(key: key, child: const SizedBox()),
    );
    await tester.pumpWidget(wrapper(const ValueKey('old')));
    await tester.pump();
    final gate = Completer<void>();
    bridge.waiting = gate;
    final notifier = container.read(windowProfileProvider.notifier) as _Profile;
    notifier.show(const AsyncData(WindowProfile.adaptive));
    await tester.pump();
    notifier.show(const AsyncData(WindowProfile.panel));
    await tester.pumpWidget(wrapper(const ValueKey('new')));
    await tester.pump();
    expect(bridge.writes.last, WindowProfile.panel);
    final count = bridge.writes.length;
    gate.complete();
    await tester.pump();
    expect(bridge.writes, hasLength(count));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(bridge.writes.last, WindowProfile.adaptive);
  });
}
