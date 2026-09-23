import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_mqtt_runtime.dart';
import 'package:larenor/features/kiosk_remote/runtime/native_managed_tablet_source.dart';

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
