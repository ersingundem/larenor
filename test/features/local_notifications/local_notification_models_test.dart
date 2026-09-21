import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/local_notifications/domain/local_notification_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

ServerContext context() => ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
});

Map<String, Object?> event({
  int sequence = 1,
  String id = 'c',
  String sensitivity = 'private',
  String? body,
  String delivery = 'delivered',
  String read = 'unread',
}) => {
  'schemaVersion': 1,
  'id': id * 32,
  'sequence': sequence,
  'category': 'security',
  'sensitivity': sensitivity,
  'title': 'Private title',
  'body': body ?? 'Private body',
  'target': '/today',
  'createdAt': 1788609600.0,
  'deliveryState': delivery,
  'readState': read,
  'acknowledged': read == 'read',
  'publicProjection': sensitivity == 'private'
      ? {'title': 'Larenor', 'body': '', 'target': null, 'redacted': true}
      : {
          'title': 'Private title',
          'body': body ?? 'Private body',
          'target': '/today',
          'redacted': false,
        },
};

Map<String, Object?> page(List<Object?> events, {int? nextAfter}) => {
  'schemaVersion': 1,
  'scope': context().toJson(),
  'subscriptionRevision': 3,
  'events': events,
  'nextAfter': nextAfter,
};

Matcher failure([String code = 'invalid_response']) =>
    isA<LarenorServerException>().having((value) => value.code, 'code', code);

void main() {
  test(
    'strict page accepts ordered events and preserves redacted projection',
    () {
      final value = LocalNotificationPage.fromJson(
        page([event(), event(sequence: 2, id: 'd', sensitivity: 'public')]),
        context: context(),
        expectedRevision: 3,
        after: 0,
      );
      expect(value.events, hasLength(2));
      expect(value.events.first.projection.redacted, isTrue);
      expect(value.events.first.projection.body, isEmpty);
      expect(value.events.last.projection.redacted, isFalse);
      expect(LocalNotificationRoutePolicy.allowed('/today'), '/today');
      expect(
        LocalNotificationRoutePolicy.allowed('https://evil.invalid'),
        isNull,
      );
      expect(LocalNotificationRoutePolicy.allowed('/security/private'), isNull);
    },
  );

  test(
    'duplicate out-of-order conflicting and unsafe responses fail closed',
    () {
      for (final value in [
        page([event(sequence: 2), event(sequence: 1, id: 'd')]),
        page([event(), event(sequence: 2)]),
        page([event()], nextAfter: 2),
        page([
          {...event(), 'target': '//evil.invalid'},
        ]),
        page([
          {...event(), 'readState': 'read', 'acknowledged': false},
        ]),
        page([
          {
            ...event(),
            'publicProjection': {
              'title': 'Secret',
              'body': 'Leak',
              'target': '/today',
              'redacted': true,
            },
          },
        ]),
      ]) {
        expect(
          () => LocalNotificationPage.fromJson(
            value,
            context: context(),
            expectedRevision: 3,
            after: 0,
          ),
          throwsA(failure()),
        );
      }
    },
  );
}
