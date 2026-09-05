// Simulate Riverpod's retained async states to verify fail-closed policy.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/settings/data/screen_policy_controller.dart';
import 'package:larenor/features/settings/domain/screen_program.dart';
import 'package:larenor/features/settings/presentation/screen_policy_runner.dart';
import 'package:larenor/features/settings/providers/screen_program_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Platform implements ScreenPolicyPlatform {
  final calls = <String>[];
  @override
  Future<void> keepAwake(bool value) async {
    calls.add('awake:$value');
  }

  @override
  Future<void> dim() async {
    calls.add('dim');
  }

  @override
  Future<void> resetBrightness() async {
    calls.add('reset');
  }

  bool get awake =>
      calls.where((c) => c.startsWith('awake:')).last == 'awake:true';
}

class _Program extends ScreenProgramNotifier {
  _Program(this.initial);
  final ScreenProgram initial;
  @override
  Future<ScreenProgram> build() async => initial;
  void publish(AsyncValue<ScreenProgram> value) => state = value;
}

const _focused = WindowPolicySnapshot(
  supported: true,
  isResumed: true,
  hasWindowFocus: true,
  reason: WindowRestrictionReason.none,
);
ScreenProgram _night() => ScreenProgram(
  enabled: true,
  rules: [
    ScreenProgramRule(
      id: 'night',
      days: {1, 2, 3, 4, 5, 6, 7},
      startMinutes: 1320,
      endMinutes: 420,
      awake: ScreenAwakeMode.systemTimeout,
      dim: true,
    ),
  ],
);
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump();
  }
}

class _Harness {
  final platform = _Platform();
  final windows = StreamController<WindowPolicySnapshot>.broadcast();
  late final ScreenPolicyController controller = ScreenPolicyController(
    platform,
  );
  late final program = _Program(_night());
  late final ProviderContainer container;
  DateTime now = DateTime(2026, 9, 5, 21, 59, 30);
  Future<void> mount(
    WidgetTester tester, {
    WindowPolicySnapshot? initial = _focused,
  }) async {
    SharedPreferences.setMockInitialValues({'keep_screen_on': true});
    container = ProviderContainer(
      overrides: [
        screenPolicyControllerProvider.overrideWithValue(controller),
        screenPolicyClockProvider.overrideWithValue(() => now),
        screenProgramProvider.overrideWith(() => program),
        windowPolicySnapshotProvider.overrideWith((_) async* {
          if (initial != null) yield initial;
          yield* windows.stream;
        }),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const CupertinoApp(home: ScreenPolicyRunner(child: SizedBox())),
      ),
    );
    await _flush(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    container.dispose();
    await windows.close();
  }
}

void main() {
  testWidgets(
    'minute boundary applies a daily window and releases at exclusive end',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      expect(h.platform.awake, isTrue);
      h.now = DateTime(2026, 9, 5, 22);
      await tester.pump(const Duration(seconds: 30));
      await _flush(tester);
      expect(h.platform.awake, isFalse);
      expect(h.platform.calls.last, 'dim');
      h.now = DateTime(2026, 9, 6, 7);
      await tester.pump(const Duration(minutes: 1));
      await _flush(tester);
      expect(h.platform.awake, isTrue);
      expect(h.platform.calls.last, 'reset');
      await h.close(tester);
    },
  );
  testWidgets(
    'clock and timezone jump reevaluates current wall time without replaying missed periods',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      h.now = DateTime(2026, 9, 6, 9);
      await tester.pump(const Duration(seconds: 30));
      await _flush(tester);
      expect(h.platform.calls, isNot(contains('dim')));
      h.now = DateTime(2026, 9, 6, 1);
      await tester.pump(const Duration(minutes: 1));
      await _flush(tester);
      expect(h.platform.calls.last, 'dim');
      await h.close(tester);
    },
  );
  testWidgets(
    'background releases brightness, leaves no schedule timer and reevaluates on resume',
    (tester) async {
      final h = _Harness()..now = DateTime(2026, 9, 5, 23);
      await h.mount(tester);
      expect(h.platform.calls.last, 'dim');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _flush(tester);
      expect(h.platform.awake, isFalse);
      expect(h.platform.calls.last, 'reset');
      final before = h.platform.calls.length;
      h.now = DateTime(2026, 9, 6, 11);
      await tester.pump(const Duration(days: 3));
      await _flush(tester);
      expect(h.platform.calls.length, before);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);
      expect(h.platform.awake, isTrue);
      await h.close(tester);
    },
  );
  for (final status in <String, WindowPolicySnapshot>{
    'unknown': WindowPolicySnapshot.unknown,
    'unfocused': const WindowPolicySnapshot(
      supported: true,
      isResumed: true,
      reason: WindowRestrictionReason.noFocus,
    ),
    'external': const WindowPolicySnapshot(
      supported: true,
      isResumed: true,
      hasWindowFocus: true,
      isExternalDisplay: true,
      reason: WindowRestrictionReason.externalDisplay,
    ),
    'PiP': const WindowPolicySnapshot(
      supported: true,
      isResumed: true,
      hasWindowFocus: true,
      isPictureInPicture: true,
      reason: WindowRestrictionReason.pictureInPicture,
    ),
  }.entries) {
    testWidgets(
      '${status.key} window releases screen demand until focused evidence returns',
      (tester) async {
        final h = _Harness();
        await h.mount(tester);
        expect(h.platform.awake, isTrue);
        h.windows.add(status.value);
        await _flush(tester);
        expect(h.platform.awake, isFalse);
        final count = h.platform.calls.length;
        await tester.pump(const Duration(hours: 3));
        await _flush(tester);
        expect(h.platform.calls.length, count);
        h.windows.add(_focused);
        await _flush(tester);
        expect(h.platform.awake, isTrue);
        await h.close(tester);
      },
    );
  }
  testWidgets(
    'unresolved or failed native observation is not permission to keep awake',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, initial: null);
      expect(h.platform.awake, isFalse);
      h.windows.addError(StateError('native failed'));
      await _flush(tester);
      expect(h.platform.awake, isFalse);
      h.windows.add(_focused);
      await _flush(tester);
      expect(h.platform.awake, isTrue);
      await h.close(tester);
    },
  );
  testWidgets(
    'native view focus events are scoped to the owning Flutter view',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      void focus(int id, ViewFocusState state) =>
          tester.binding.handleViewFocusChanged(
            ViewFocusEvent(
              viewId: id,
              state: state,
              direction: ViewFocusDirection.undefined,
            ),
          );
      focus(tester.view.viewId + 1, ViewFocusState.unfocused);
      await _flush(tester);
      expect(h.platform.awake, isTrue);
      focus(tester.view.viewId, ViewFocusState.unfocused);
      await _flush(tester);
      expect(h.platform.awake, isFalse);
      focus(tester.view.viewId, ViewFocusState.focused);
      await _flush(tester);
      expect(h.platform.awake, isTrue);
      await h.close(tester);
    },
  );
  testWidgets(
    'loading and error previous values never retain a keep-awake or dim policy',
    (tester) async {
      final h = _Harness()..now = DateTime(2026, 9, 5, 23);
      await h.mount(tester);
      expect(h.platform.calls.last, 'dim');
      h.program.publish(
        const AsyncLoading<ScreenProgram>().copyWithPrevious(
          AsyncData(_night()),
        ),
      );
      await _flush(tester);
      expect(h.platform.calls.last, 'reset');
      h.program.publish(
        AsyncError<ScreenProgram>(
          StateError('storage'),
          StackTrace.current,
        ).copyWithPrevious(AsyncData(_night())),
      );
      await _flush(tester);
      expect(h.platform.awake, isFalse);
      h.program.publish(AsyncData(_night()));
      await _flush(tester);
      expect(h.platform.calls.last, 'dim');
      await h.close(tester);
    },
  );
}
