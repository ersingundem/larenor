import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/local_notifications/data/local_notification_controller.dart';
import 'package:larenor/features/local_notifications/data/local_notification_platform.dart';
import 'package:larenor/features/local_notifications/data/local_notification_runtime.dart';
import 'package:larenor/features/local_notifications/data/local_notification_store.dart';
import 'package:larenor/features/local_notifications/domain/local_notification_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _SessionStore implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? session) async {}
}

final class _SourceStore implements HomeSourcePersistence {
  @override
  Future<HomeSource> read() async => HomeSource.verifiedCore;

  @override
  Future<void> write(HomeSource source) async {}
}

final class _FileStore implements LocalNotificationStoreBackend {
  _FileStore(this.file);
  final File file;

  Future<Map<String, String>> _values() async {
    if (!await file.exists()) return {};
    final value = jsonDecode(await file.readAsString());
    if (value is! Map) throw const FormatException('invalid fixture store');
    return value.map((key, item) => MapEntry(key as String, item as String));
  }

  @override
  Future<String?> read(String key) async => (await _values())[key];

  @override
  Future<void> write(String key, String value) async {
    final values = await _values()
      ..[key] = value;
    await file.writeAsString(jsonEncode(values), flush: true);
  }

  @override
  Future<void> delete(String key) async {
    final values = await _values()
      ..remove(key);
    await file.writeAsString(jsonEncode(values), flush: true);
  }
}

final class _Owner extends ChangeNotifier implements LocalNotificationOwner {
  @override
  bool get isCurrent => true;
}

final class _Permission implements LocalNotificationPermissionGateway {
  @override
  Future<LocalNotificationPermission> read() async =>
      LocalNotificationPermission.systemAllowed;
}

final class _Platform implements LocalNotificationPlatform {
  final tapsController = StreamController<LocalNotificationTap>.broadcast();
  final status = const AndroidNotificationStatus(
    permission: AndroidNotificationPermission.granted,
    channelEnabled: true,
    recoveryRequired: false,
    batteryOptimizationExempt: false,
    deliveryMode: 'foregroundPull',
  );
  int reconciles = 0;

  @override
  Stream<LocalNotificationTap> get taps => tapsController.stream;

  @override
  Future<AndroidNotificationStatus> probe({required bool Function() current}) {
    if (!current()) throw StateError('stale');
    return Future.value(status);
  }

  @override
  Future<AndroidNotificationStatus> reconcile({
    required ServerSession session,
    required LocalNotificationSubscription subscription,
    required List<LocalNotificationEvent> events,
    required bool Function() current,
  }) {
    if (!current()) throw StateError('stale');
    reconciles++;
    return Future.value(status);
  }

  @override
  Future<AndroidNotificationStatus> requestPermission({
    required bool Function() current,
  }) => probe(current: current);

  @override
  Future<LocalNotificationDeliveryRegistration> prepareBackgroundDelivery({
    required ServerSession session,
    required LocalNotificationSubscription subscription,
    required DateTime expiresAt,
    required bool Function() current,
  }) => throw StateError('background delivery is not used over HTTP');

  @override
  Future<void> activateBackgroundDelivery({
    required LocalNotificationDeliveryLease lease,
    required bool Function() current,
  }) => throw StateError('background delivery is not used over HTTP');

  @override
  Future<void> disableBackgroundDelivery({
    required AndroidBackgroundDelivery delivery,
    required bool Function() current,
  }) => throw StateError('background delivery is not used over HTTP');

  @override
  Future<void> cancelPreparedBackgroundDelivery({
    required AndroidBackgroundDelivery delivery,
    required bool Function() current,
  }) => throw StateError('background delivery is not used over HTTP');

  @override
  Future<void> openNotificationSettings({
    required bool Function() current,
  }) async {}

  @override
  Future<void> openPowerSettings({required bool Function() current}) async {}

  Future<void> close() => tapsController.close();
}

Future<void> _settle(LocalNotificationController controller) async {
  for (var count = 0; count < 400 && controller.busy; count++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(controller.busy, isFalse);
}

void main() {
  final coreUrl = Platform.environment['LARENOR_F54_CORE_URL'];
  final phase = Platform.environment['LARENOR_F54_PHASE'];
  final storePath = Platform.environment['LARENOR_F54_STORE_FILE'];

  setUpAll(() => HttpOverrides.global = null);

  test('real Client persists the subscription and deduplicates a safe tap after restart', () async {
    final account = ServerAccountController(store: _SessionStore());
    addTearDown(account.dispose);
    await account.signIn(
      baseUrl: coreUrl!,
      username: 'admin',
      password: 'Synthetic new password 2026',
      deviceName: 'F54 notification acceptance',
    );
    expect(account.failure, isNull);
    final home = HomeSessionController(store: _SourceStore(), account: account);
    addTearDown(home.dispose);
    await home.initialize();
    home.runtimeMounted(home.runtimeIdentity);
    final owner = _Owner();
    addTearDown(owner.dispose);
    final controller = LocalNotificationController(
      home: home,
      apiFactory: (endpoint) => LarenorServerApi(endpoint: endpoint),
      store: LocalNotificationStore(backend: _FileStore(File(storePath!))),
      permissionGateway: _Permission(),
      clock: () => DateTime.now().toUtc(),
      windowCurrent: () => true,
      owner: owner,
    );
    final platform = _Platform();
    addTearDown(platform.close);
    final routes = <String>[];
    final runtime = LocalNotificationRuntimeCoordinator(
      home: home,
      controller: controller,
      platform: platform,
      clock: () => DateTime.now().toUtc(),
      active: () => true,
      navigate: routes.add,
      pollInterval: const Duration(hours: 1),
    );
    addTearDown(runtime.dispose);
    runtime.setEnabled(true);
    await _settle(controller);
    for (var count = 0; count < 100 && runtime.platformBusy; count++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(controller.loaded, isTrue);
    expect(controller.failure, isNull);
    expect(runtime.backgroundEndpointUsesTls, isFalse);
    expect(runtime.canEnableBackground, isFalse);

    if (phase == 'create') {
      expect(controller.events, hasLength(1));
      final privateEvent = controller.events.single;
      expect(privateEvent.sensitivity, LocalNotificationSensitivity.private);
      expect(privateEvent.projection.redacted, isTrue);
      expect(privateEvent.projection.target, isNull);
      expect(
        await controller.markRead(privateEvent, interactionCurrent: () => true),
        isTrue,
      );
      expect(routes, isEmpty);
    } else {
      expect(phase, 'restart');
      expect(controller.events, hasLength(2));
      final publicEvent = controller.events.singleWhere(
        (event) => event.sensitivity == LocalNotificationSensitivity.public,
      );
      expect(publicEvent.target, '/today');
      expect(publicEvent.readState, LocalNotificationReadState.unread);
      final tap = LocalNotificationTap(
        bindingId: AndroidLocalNotificationPlatform.bindingId(account.session!),
        subscriptionRevision: controller.subscription!.revision,
        eventId: publicEvent.id,
        sequence: publicEvent.sequence,
      );
      platform.tapsController.add(tap);
      platform.tapsController.add(tap);
      for (var count = 0; count < 200 && routes.isEmpty; count++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(routes, ['/today']);
      expect(
        controller.events
            .singleWhere((event) => event.id == publicEvent.id)
            .readState,
        LocalNotificationReadState.read,
      );
    }
  }, skip: coreUrl == null || phase == null || storePath == null);
}
