import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/local_notifications/data/local_notification_platform.dart';
import 'package:larenor/features/local_notifications/domain/local_notification_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const channel = MethodChannel('test/local-notifications');

ServerSession session() => ServerSession(
  endpoint: ServerEndpoint('https://core.invalid'),
  accessToken: 'x' * 43,
  refreshToken: 'y' * 43,
  expiresAt: DateTime.utc(2026, 10),
  context: ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': 'a' * 32,
    'homeId': 'b' * 32,
  }),
  user: ServerUser(
    id: 'c' * 32,
    username: 'fixture',
    role: ServerRole.member,
    mustChangePassword: false,
  ),
);

LocalNotificationSubscription subscription() => LocalNotificationSubscription(
  id: 'd' * 32,
  revision: 3,
  permission: LocalNotificationPermission.inAppOnly,
  expiresAt: DateTime.utc(2026, 10),
);

LocalNotificationEvent event(int sequence, {bool private = false}) =>
    LocalNotificationEvent.fromJson({
      'schemaVersion': 1,
      'id': (sequence == 1 ? 'e' : 'f') * 32,
      'sequence': sequence,
      'category': 'security',
      'sensitivity': private ? 'private' : 'public',
      'title': private ? 'Secret' : 'Door',
      'body': private ? 'Private body' : 'Opened',
      'target': '/today',
      'createdAt': 1788609600.0 + sequence,
      'deliveryState': 'delivered',
      'readState': 'unread',
      'acknowledged': false,
      'publicProjection': private
          ? {'title': 'Larenor', 'body': '', 'target': null, 'redacted': true}
          : {
              'title': 'Door',
              'body': 'Opened',
              'target': '/today',
              'redacted': false,
            },
    });

Map<String, Object?> status({String permission = 'granted'}) => {
  'schemaVersion': 1,
  'supported': true,
  'permission': permission,
  'channelVersion': 1,
  'channelEnabled': true,
  'bindingId': null,
  'subscriptionRevision': 0,
  'lastSequence': 0,
  'recoveryRequired': false,
  'batteryOptimizationExempt': false,
  'deliveryMode': 'foregroundPull',
};

Matcher failure(String code) =>
    isA<LarenorServerException>().having((error) => error.code, 'code', code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('probe and explicit permission denial are fail closed', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'probe') return status(permission: 'notRequested');
      throw PlatformException(
        code: 'denied',
        message: 'private native detail',
        details: {'token': 'secret'},
      );
    });
    final platform = AndroidLocalNotificationPlatform(
      methods: channel,
      supported: true,
    );
    expect(
      (await platform.probe(current: () => true)).permission,
      AndroidNotificationPermission.notRequested,
    );
    await expectLater(
      platform.requestPermission(current: () => true),
      throwsA(failure('denied')),
    );
  });

  test(
    'reconcile sends only scoped projection and never full private text',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return status();
      });
      final platform = AndroidLocalNotificationPlatform(
        methods: channel,
        supported: true,
      );
      await platform.reconcile(
        session: session(),
        subscription: subscription(),
        events: [event(2), event(1, private: true)],
        current: () => true,
      );
      expect(calls.map((call) => call.method), ['bind', 'reconcile']);
      final bind = calls.first.arguments as Map;
      expect(bind['bindingId'], hasLength(64));
      expect(bind.values, isNot(contains('a' * 32)));
      expect(bind.values, isNot(contains('c' * 32)));
      final payload = calls.last.arguments as Map;
      final events = payload['events'] as List;
      expect(events.map((raw) => (raw as Map)['sequence']), [1, 2]);
      expect(events.first['title'], 'Larenor');
      expect(events.first['body'], isEmpty);
      expect(payload.toString(), isNot(contains('Private body')));
      expect(payload.toString(), isNot(contains('/today')));
    },
  );

  test(
    'late method result is rejected after route or account retires',
    () async {
      final gate = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => gate.future);
      var current = true;
      final platform = AndroidLocalNotificationPlatform(
        methods: channel,
        supported: true,
      );
      final pending = platform.probe(current: () => current);
      current = false;
      gate.complete(status());
      await expectLater(pending, throwsA(failure('cancelled')));
    },
  );

  test('malformed native status and non-Android support are honest', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {...status(), 'unknown': true},
    );
    final malformed = AndroidLocalNotificationPlatform(
      methods: channel,
      supported: true,
    );
    await expectLater(
      malformed.probe(current: () => true),
      throwsA(failure('invalid_response')),
    );
    final unsupported = AndroidLocalNotificationPlatform(supported: false);
    final value = await unsupported.probe(current: () => true);
    expect(value.permission, AndroidNotificationPermission.unsupported);
    expect(value.canPresent, isFalse);
  });

  test('tap envelope keeps exact account revision and event authority', () {
    final tap = LocalNotificationTap.fromJson({
      'schemaVersion': 1,
      'bindingId': 'a' * 64,
      'subscriptionRevision': 3,
      'eventId': 'b' * 32,
      'sequence': 9,
    });
    expect(tap.bindingId, 'a' * 64);
    expect(tap.subscriptionRevision, 3);
    expect(tap.eventId, 'b' * 32);
    expect(tap.sequence, 9);
    for (final invalid in [
      {
        'schemaVersion': 1,
        'bindingId': 'a' * 64,
        'subscriptionRevision': 3,
        'eventId': 'b' * 32,
        'sequence': 9,
        'route': '/private',
      },
      {
        'schemaVersion': 1,
        'bindingId': 'c' * 32,
        'subscriptionRevision': 3,
        'eventId': 'b' * 32,
        'sequence': 9,
      },
    ]) {
      expect(
        () => LocalNotificationTap.fromJson(invalid),
        throwsA(failure('invalid_response')),
      );
    }
  });
}
