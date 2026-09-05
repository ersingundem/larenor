import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/settings/presentation/idle_gate.dart';
import 'package:larenor/features/settings/presentation/screen_policy_runner.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/core/window/window_policy_bridge.dart';
import 'package:larenor/features/settings/providers/screen_program_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _WakelockCodec extends StandardMessageCodec {
  const _WakelockCodec();
  @override
  Object? readValueOfType(int type, ReadBuffer buffer) =>
      type == 129 ? readValue(buffer) : super.readValueOfType(type, buffer);
}

const _wakelockChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
  _WakelockCodec(),
);
const _brightnessChannel = MethodChannel(
  'github.com/aaassseee/screen_brightness',
);

void main() {
  testWidgets(
    'wakelock policy serializes slow plugin calls and releases on disposal',
    (tester) async {
      SharedPreferences.setMockInitialValues({'keep_screen_on': true});
      final pending = Completer<void>();
      final values = <bool>[];
      var active = 0;
      var maximum = 0;
      tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
        _wakelockChannel,
        (message) async {
          final enable = ((message as List).first as List).first as bool;
          values.add(enable);
          active++;
          if (active > maximum) maximum = active;
          if (enable && !pending.isCompleted) await pending.future;
          active--;
          return <Object?>[null];
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler(_wakelockChannel, null),
      );
      final container = ProviderContainer(
        overrides: [
          windowPolicyBridgeProvider.overrideWithValue(
            WindowPolicyBridge(isAndroid: false),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const CupertinoApp(
            home: ScreenPolicyRunner(child: SizedBox()),
          ),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(container.read(screenProgramProvider).hasValue, isTrue);
      expect(container.read(windowPolicySnapshotProvider).hasValue, isTrue);
      expect(values.last, isTrue);
      await container.read(keepScreenOnProvider.notifier).set(false);
      await tester.pump();
      expect(values.last, isTrue);
      pending.complete();
      await tester.pump();
      expect(values.last, isFalse);
      expect(maximum, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'night dimming restores app brightness on disable and background',
    (tester) async {
      final now = DateTime.now();
      final minutes = now.hour * 60 + now.minute;
      SharedPreferences.setMockInitialValues({
        'keep_screen_on': true,
        'night_start_minutes': (minutes + 1439) % 1440,
        'night_end_minutes': (minutes + 2) % 1440,
        'dim_brightness_at_night': true,
      });
      final brightness = <String>[];
      final wakelock = <bool>[];
      tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
        _wakelockChannel,
        (message) async {
          wakelock.add(((message as List).first as List).first as bool);
          return <Object?>[null];
        },
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _brightnessChannel,
        (call) async {
          brightness.add(call.method);
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
          _wakelockChannel,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          _brightnessChannel,
          null,
        );
      });
      final container = ProviderContainer(
        overrides: [
          windowPolicyBridgeProvider.overrideWithValue(
            WindowPolicyBridge(isAndroid: false),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const CupertinoApp(
            home: ScreenPolicyRunner(child: SizedBox()),
          ),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(container.read(screenProgramProvider).hasValue, isTrue);
      expect(container.read(windowPolicySnapshotProvider).hasValue, isTrue);
      expect(brightness, ['setApplicationScreenBrightness']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(wakelock.last, isFalse);
      expect(brightness.last, 'resetApplicationScreenBrightness');
      await tester.pump(const Duration(hours: 2));
      expect(brightness, hasLength(2));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(wakelock.last, isTrue);
      expect(brightness.last, 'setApplicationScreenBrightness');
      await container
          .read(nightWindowProvider.notifier)
          .setDimBrightnessAtNight(false);
      await tester.pump();
      expect(brightness.last, 'resetApplicationScreenBrightness');
      expect(brightness.any((method) => method.contains('System')), isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('unsupported wakelock does not escape timer or disposal', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'keep_screen_on': true});
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
      _wakelockChannel,
      (_) async => ['unsupported', 'No platform support', null],
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
        _wakelockChannel,
        null,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          windowPolicyBridgeProvider.overrideWithValue(
            WindowPolicyBridge(isAndroid: false),
          ),
        ],
        child: const CupertinoApp(home: ScreenPolicyRunner(child: SizedBox())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'idle countdown pauses in background and starts fresh on resume',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'idle_mode_enabled': true,
        'idle_timeout_minutes': 1,
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            haRestClientProvider.overrideWithValue(null),
            haWebSocketClientProvider.overrideWithValue(null),
          ],
          child: const CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: IdleGate(child: SizedBox()),
          ),
        ),
      );
      await tester.pump();
      final clock = find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            RegExp(r'^\d{2}:\d{2}$').hasMatch(widget.data ?? ''),
      );
      await tester.pump(const Duration(seconds: 30));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 5));
      expect(clock, findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 59));
      expect(clock, findsNothing);
      await tester.pump(const Duration(seconds: 1));
      expect(clock, findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(clock, findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 5));
      expect(tester.takeException(), isNull);
    },
  );
}
