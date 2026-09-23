import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_mqtt_runtime.dart';
import 'package:larenor/features/kiosk_remote/runtime/native_managed_tablet_source.dart';

final class _Actions implements ManagedTabletLocalActions {
  _Actions({this.gate, this.fail = false});

  final Completer<void>? gate;
  final bool fail;
  int refreshes = 0;

  @override
  Future<void> refreshDashboard({required bool Function() isCurrent}) async {
    refreshes++;
    await gate?.future;
    if (fail) throw StateError('fixture_failure');
    if (!isCurrent()) throw StateError('fixture_retired');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(NativeManagedTabletSource.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('listener is disabled by default and does not touch Android', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls += 1;
      return null;
    });
    final source = NativeManagedTabletSource(isAndroid: true);

    final lease = await source.bind('account:core:home:session');

    expect(lease, isNull);
    expect(source.status, NativeManagedTabletSourceStatus.disabled);
    expect(calls, 0);
  });

  test('active lease parses only the bounded secret-free snapshot', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'start') return {'status': 'active'};
      if (call.method == 'snapshot') {
        return {
          'schemaVersion': 1,
          'batteryPercent': 73,
          'network': 'wifi',
          'appVersion': '1.2.3+45',
          'appForeground': true,
          'kioskState': 'locked',
        };
      }
      return null;
    });
    final source = NativeManagedTabletSource(
      config: const NativeManagedTabletSourceConfig(enabled: true),
      isAndroid: true,
      sessionId: () => 'a' * 32,
    );

    final lease = await source.bind('account:core:home:session');
    final telemetry = await lease!.readTelemetry();

    expect(telemetry.values(), {
      'battery': 73,
      'network': 'wifi',
      'app_version': '1.2.3+45',
      'app_foreground': true,
      'kiosk_state': 'locked',
    });
    expect(calls.map((call) => call.method), ['start', 'snapshot']);
    final wire = calls
        .expand((call) sync* {
          yield call.method;
          yield call.arguments.toString();
        })
        .join(' ');
    expect(wire, isNot(contains('token')));
    expect(wire, isNot(contains('password')));
    expect(wire, isNot(contains('://')));
  });

  test('malformed and oversized native snapshots fail closed', () async {
    var snapshot = <String, Object?>{};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') return {'status': 'active'};
      if (call.method == 'snapshot') return snapshot;
      return null;
    });
    final source = NativeManagedTabletSource(
      config: const NativeManagedTabletSourceConfig(enabled: true),
      isAndroid: true,
      sessionId: () => 'b' * 32,
    );
    final lease = await source.bind('scope');

    for (final invalid in [
      {
        'schemaVersion': 1,
        'batteryPercent': 101,
        'network': 'wifi',
        'appVersion': '1',
        'appForeground': true,
        'kioskState': 'none',
      },
      {
        'schemaVersion': 1,
        'batteryPercent': 50,
        'network': 'ssid:private-home',
        'appVersion': '1',
        'appForeground': true,
        'kioskState': 'none',
      },
      {
        'schemaVersion': 1,
        'batteryPercent': 50,
        'network': 'wifi',
        'appVersion': 'x' * 65,
        'appForeground': true,
        'kioskState': 'none',
      },
      {
        'schemaVersion': 1,
        'batteryPercent': 50,
        'network': 'wifi',
        'appVersion': '1',
        'appForeground': false,
        'kioskState': 'none',
        'token': 'must-not-cross',
      },
    ]) {
      snapshot = invalid;
      await expectLater(lease!.readTelemetry(), throwsFormatException);
    }
  });

  test(
    'scope and lifecycle retirement reject a late native callback',
    () async {
      final pending = Completer<Object?>();
      final stops = <Object?>[];
      var sequence = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') return {'status': 'active'};
        if (call.method == 'snapshot') return pending.future;
        if (call.method == 'stop') stops.add(call.arguments);
        return null;
      });
      final source = NativeManagedTabletSource(
        config: const NativeManagedTabletSourceConfig(enabled: true),
        isAndroid: true,
        sessionId: () => (++sequence).toString().padLeft(32, '0'),
      );
      final old = await source.bind('session-one');
      final late = old!.readTelemetry();

      final current = await source.bind('session-two');
      pending.complete({
        'schemaVersion': 1,
        'batteryPercent': 50,
        'network': 'offline',
        'appVersion': '1',
        'appForeground': true,
        'kioskState': 'none',
      });

      await expectLater(late, throwsStateError);
      expect(
        await old.commandExecutor.execute('refreshDashboard'),
        ManagedTabletCommandResult.denied,
      );
      expect(
        await current!.commandExecutor.execute('refreshDashboard'),
        ManagedTabletCommandResult.unsupported,
      );
      await source.setForeground(false);
      expect(
        await current.commandExecutor.execute('refreshDashboard'),
        ManagedTabletCommandResult.denied,
      );
      expect(stops, hasLength(2));
    },
  );

  test('lifecycle retirement closes a pending native start', () async {
    final start = Completer<Object?>();
    final stops = <Object?>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') return start.future;
      if (call.method == 'stop') stops.add(call.arguments);
      return null;
    });
    final source = NativeManagedTabletSource(
      config: const NativeManagedTabletSourceConfig(enabled: true),
      isAndroid: true,
      sessionId: () => 'c' * 32,
    );

    final binding = source.bind('scope');
    await Future<void>.delayed(Duration.zero);
    await source.setForeground(false);
    start.complete({'status': 'active'});

    await expectLater(binding, throwsStateError);
    expect(source.status, NativeManagedTabletSourceStatus.retired);
    expect(stops, isNotEmpty);
  });

  test(
    'unsupported platforms remain disabled without channel traffic',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls += 1;
        return null;
      });
      final source = NativeManagedTabletSource(
        config: const NativeManagedTabletSourceConfig(enabled: true),
        isAndroid: false,
      );

      expect(await source.bind('scope'), isNull);
      expect(source.status, NativeManagedTabletSourceStatus.unsupported);
      expect(calls, 0);
    },
  );

  test('current lease executes only the bounded dashboard refresh', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') return {'status': 'active'};
      return null;
    });
    final actions = _Actions();
    final source = NativeManagedTabletSource(
      config: const NativeManagedTabletSourceConfig(enabled: true),
      actions: actions,
      isAndroid: true,
      sessionId: () => 'd' * 32,
    );
    final lease = await source.bind('scope');

    expect(
      await lease!.commandExecutor.execute('refreshDashboard'),
      ManagedTabletCommandResult.succeeded,
    );
    expect(actions.refreshes, 1);
    for (final unsupported in ['syncProfile', 'lockKiosk', 'unknown']) {
      expect(
        await lease.commandExecutor.execute(unsupported),
        ManagedTabletCommandResult.unsupported,
      );
    }
    expect(actions.refreshes, 1);
  });

  test('retirement wins over a delayed dashboard refresh', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') return {'status': 'active'};
      return null;
    });
    final gate = Completer<void>();
    final actions = _Actions(gate: gate);
    final source = NativeManagedTabletSource(
      config: const NativeManagedTabletSourceConfig(enabled: true),
      actions: actions,
      isAndroid: true,
      sessionId: () => 'e' * 32,
    );
    final lease = await source.bind('scope');

    final result = lease!.commandExecutor.execute('refreshDashboard');
    await Future<void>.delayed(Duration.zero);
    expect(
      await lease.commandExecutor.execute('refreshDashboard'),
      ManagedTabletCommandResult.denied,
    );
    await source.setForeground(false);
    gate.complete();

    expect(await result, ManagedTabletCommandResult.denied);
    expect(actions.refreshes, 1);
    expect(
      await lease.commandExecutor.execute('refreshDashboard'),
      ManagedTabletCommandResult.denied,
    );
  });

  test('dashboard refresh failures are bounded and reported', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') return {'status': 'active'};
      return null;
    });
    final actions = _Actions(fail: true);
    final source = NativeManagedTabletSource(
      config: const NativeManagedTabletSourceConfig(enabled: true),
      actions: actions,
      isAndroid: true,
      sessionId: () => 'f' * 32,
    );
    final lease = await source.bind('scope');

    expect(
      await lease!.commandExecutor.execute('refreshDashboard'),
      ManagedTabletCommandResult.failed,
    );
    expect(actions.refreshes, 1);
  });
}
