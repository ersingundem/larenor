import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/today/providers/today_providers.dart';

import '../ha_client/fake_socket.dart';
import 'fake_today_api.dart';

class _Config extends ConnectionConfig {
  Future<HaConnectionConfig?>? pending;
  @override
  Future<HaConnectionConfig?> build() =>
      pending ??
      Future.value(
        const HaConnectionConfig(baseUrl: 'http://ha.test', token: 'fixture'),
      );
  void reload(Future<HaConnectionConfig?> value) {
    pending = value;
    ref.invalidateSelf();
  }
}

void main() {
  testWidgets(
    'Today polling and subscriptions stop in background, resume and dispose',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final api = FakeTodayApi();
      final connection = StreamController<HaConnectionStatus>.broadcast();
      final container = ProviderContainer(
        overrides: [
          todayApiProvider.overrideWith((_) => api),
          todayConnectionProvider.overrideWith((_) => connection.stream),
        ],
      );
      final listener = container.listen(todayProvider, (_, _) {});
      addTearDown(container.dispose);
      await tester.pump();
      expect(api.configCalls, 1);
      connection.add(HaConnectionStatus.connected);
      await tester.pump();
      expect(api.subscriptions, hasLength(1));
      final before = api.configCalls;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 5));
      expect(api.configCalls, before);
      expect(api.cancelled, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(api.configCalls, before + 1);
      expect(api.subscriptions, hasLength(2));
      listener.close();
      await tester.pump();
      container.dispose();
      final after = api.configCalls;
      await tester.pump(const Duration(minutes: 5));
      expect(api.configCalls, after);
      expect(api.cancelled, 2);
      expect(api.serviceCalls, isEmpty);
      await connection.close();
    },
  );

  testWidgets(
    'new account ignores old pending snapshot and resets local read state',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final old = FakeTodayApi();
      final pending = Completer<void>();
      old.beforeConfig = () => pending.future;
      var active = old;
      final container = ProviderContainer(
        overrides: [
          todayApiProvider.overrideWith((_) => active),
          todayConnectionProvider.overrideWith(
            (_) => Stream.value(HaConnectionStatus.disconnected),
          ),
        ],
      );
      final listener = container.listen(todayProvider, (_, _) {});
      addTearDown(container.dispose);
      await tester.pump();
      active = FakeTodayApi()
        ..notifications = [notification(id: 'new-account')];
      container.invalidate(todayApiProvider);
      container.read(todayProvider);
      await tester.pump();
      await tester.pump();
      expect(identical(container.read(todayApiProvider), active), isTrue);
      expect(active.configCalls, 1);
      expect(container.read(todayControllerProvider)?.snapshot, isNotNull);
      expect(
        container.read(todayProvider).value!.notifications.value!.single.id,
        'new-account',
      );
      pending.complete();
      await tester.pump();
      expect(
        container.read(todayProvider).value!.notifications.value!.single.id,
        'new-account',
      );
      expect(old.serviceCalls, isEmpty);
      listener.close();
      container.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'loading or failed config never produces transport from previous credential value',
    (tester) async {
      final rest = HaRestClient(baseUrl: 'http://ha.test', token: 'fixture');
      final ws = HaWebSocketClient(
        baseUrl: 'http://ha.test',
        token: 'fixture',
        channelFactory: (_) => FakeSocket(),
      );
      final container = ProviderContainer(
        overrides: [
          connectionConfigProvider.overrideWith(_Config.new),
          haRestClientProvider.overrideWith((_) => rest),
          haWebSocketClientProvider.overrideWith((_) => ws),
          entitiesProvider.overrideWith(_EmptyEntities.new),
        ],
      );
      final listener = container.listen(todayApiProvider, (_, _) {});
      addTearDown(container.dispose);
      await tester.pump();
      expect(container.read(todayApiProvider), isNotNull);
      final loading = Completer<HaConnectionConfig?>();
      (container.read(connectionConfigProvider.notifier) as _Config).reload(
        loading.future,
      );
      container.read(connectionConfigProvider);
      await tester.pump();
      expect(container.read(connectionConfigProvider).value, isNotNull);
      expect(container.read(todayApiProvider), isNull);
      loading.completeError(StateError('Fixture'));
      await tester.pump();
      expect(container.read(todayApiProvider), isNull);
      listener.close();
      container.dispose();
      rest.dispose();
      ws.dispose();
      await tester.pump();
    },
  );
}

class _EmptyEntities extends Entities {
  @override
  Future<Map<String, Never>> build() async => {};
}
