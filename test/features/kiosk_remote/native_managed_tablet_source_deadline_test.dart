import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_mqtt_runtime.dart';
import 'package:larenor/features/kiosk_remote/runtime/native_managed_tablet_source.dart';

final class _GatedActions implements ManagedTabletLocalActions {
  final gate = Completer<void>();
  bool Function()? commandCurrent;
  int lateEffects = 0;

  @override
  Future<void> refreshDashboard({required bool Function() isCurrent}) async {}

  @override
  Future<void> syncProfile({
    required String clientVersion,
    required bool Function() isCurrent,
  }) async {
    commandCurrent = isCurrent;
    await gate.future;
    if (isCurrent()) lateEffects++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(NativeManagedTabletSource.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const config = NativeManagedTabletSourceConfig(
    enabled: true,
    nativeCallTimeout: Duration(milliseconds: 10),
  );

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'pending native start has one total deadline and exact cleanup',
    () async {
      final start = Completer<Object?>();
      final stops = <Object?>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') return start.future;
        if (call.method == 'stop') stops.add(call.arguments);
        return null;
      });
      final source = NativeManagedTabletSource(
        config: config,
        channel: channel,
        isAndroid: true,
        sessionId: () => '1' * 32,
      );

      await expectLater(
        source.bind('scope'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'native_tablet_source_timeout',
          ),
        ),
      );

      expect(source.status, NativeManagedTabletSourceStatus.failed);
      expect(stops, [
        {'sessionId': '1' * 32},
      ]);
      start.complete({'status': 'active'});
    },
  );

  test('pending snapshot has one total deadline', () async {
    final snapshot = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') return {'status': 'active'};
      if (call.method == 'snapshot') return snapshot.future;
      return null;
    });
    final source = NativeManagedTabletSource(
      config: config,
      channel: channel,
      isAndroid: true,
      sessionId: () => '2' * 32,
    );
    final lease = await source.bind('scope');

    await expectLater(
      lease!.readTelemetry(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'native_tablet_source_timeout',
        ),
      ),
    );
    snapshot.complete(null);
  });

  test(
    'local action timeout retires lease before late work can commit',
    () async {
      final actions = _GatedActions();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') return {'status': 'active'};
        if (call.method == 'snapshot') {
          return {
            'schemaVersion': 1,
            'batteryPercent': 80,
            'network': 'wifi',
            'appVersion': '1.2.3',
            'appForeground': true,
            'kioskState': 'locked',
          };
        }
        return null;
      });
      final source = NativeManagedTabletSource(
        config: const NativeManagedTabletSourceConfig(
          enabled: true,
          nativeCallTimeout: Duration(milliseconds: 30),
        ),
        channel: channel,
        isAndroid: true,
        sessionId: () => '4' * 32,
        actions: actions,
      );
      final lease = await source.bind('scope');

      expect(
        await lease!.commandExecutor.execute('syncProfile'),
        ManagedTabletCommandResult.failed,
      );
      expect(actions.commandCurrent!(), isFalse);
      expect(source.status, NativeManagedTabletSourceStatus.retired);
      actions.gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(actions.lateEffects, 0);
      expect(
        await lease.commandExecutor.execute('syncProfile'),
        ManagedTabletCommandResult.denied,
      );
    },
  );

  test(
    'retirement wins immediately and late command cannot affect replacement',
    () async {
      final oldCommand = Completer<Object?>();
      var starts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') {
          starts += 1;
          return {'status': 'active'};
        }
        if (call.method == 'command') {
          final session = (call.arguments as Map)['sessionId'];
          if (session == '3' * 32) return oldCommand.future;
          return {'result': 'succeeded'};
        }
        return null;
      });
      var session = 2;
      final source = NativeManagedTabletSource(
        config: const NativeManagedTabletSourceConfig(
          enabled: true,
          nativeCallTimeout: Duration(seconds: 1),
        ),
        channel: channel,
        isAndroid: true,
        sessionId: () => '${++session}' * 32,
      );
      final oldLease = await source.bind('old-scope');
      final oldResult = oldLease!.commandExecutor.execute('lockKiosk');
      await Future<void>.delayed(Duration.zero);

      await source.setForeground(false);
      await expectLater(
        oldResult.timeout(const Duration(milliseconds: 100)),
        completion(ManagedTabletCommandResult.denied),
      );

      final current = await source.bind('new-scope');
      expect(
        await current!.commandExecutor.execute('lockKiosk'),
        ManagedTabletCommandResult.succeeded,
      );
      oldCommand.complete({'result': 'succeeded'});
      await Future<void>.delayed(Duration.zero);
      expect(starts, 2);
      expect(
        await oldLease.commandExecutor.execute('lockKiosk'),
        ManagedTabletCommandResult.denied,
      );
    },
  );
}
