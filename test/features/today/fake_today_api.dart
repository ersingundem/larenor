import 'dart:async';

import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/today/data/today_api.dart';

class FakeTodayApi implements TodayApi {
  Map<String, dynamic> config = {'time_zone': 'Europe/Istanbul'};
  List<HaEntity> entities = [todoEntity('todo.shopping')];
  List<Map<String, dynamic>> calendars = [
    {'entity_id': 'calendar.family', 'name': 'Family'},
  ];
  Map<String, Object?> items = {
    'todo.shopping': {
      'items': [todoItem()],
    },
  };
  Map<String, List<Map<String, dynamic>>> events = {
    'calendar.family': [calendarEvent()],
  };
  Object? notifications = [notification()];
  Object? configError;
  Object? entitiesError;
  Object? calendarsError;
  Object? notificationsError;
  final itemErrors = <String, Object>{};
  final calendarErrors = <String, Object>{};
  Future<void> Function()? beforeConfig;
  Future<void> Function(String)? beforeItems;
  Future<void> Function(String, String, Map<String, dynamic>, String?)?
  onService;
  final serviceCalls =
      <
        ({
          String domain,
          String service,
          Map<String, dynamic> data,
          String? entityId,
        })
      >[];
  final calendarCalls = <({String entityId, DateTime start, DateTime end})>[];
  final itemCalls = <String>[];
  final subscriptions = <StreamController<dynamic>>[];
  int cancelled = 0;
  int configCalls = 0;
  int notificationCalls = 0;

  @override
  Future<Map<String, dynamic>> getConfig() async {
    configCalls++;
    await beforeConfig?.call();
    if (configError != null) throw configError!;
    return config;
  }

  @override
  Future<List<HaEntity>> getEntities() async {
    if (entitiesError != null) throw entitiesError!;
    return entities;
  }

  @override
  Future<List<Map<String, dynamic>>> getCalendars() async {
    if (calendarsError != null) throw calendarsError!;
    return calendars;
  }

  @override
  Future<List<Map<String, dynamic>>> getCalendarEvents(
    String entityId,
    DateTime start,
    DateTime end,
  ) async {
    calendarCalls.add((entityId: entityId, start: start, end: end));
    if (calendarErrors[entityId] case final Object error) throw error;
    return events[entityId] ?? [];
  }

  @override
  Future<Object?> getTodoItems(String entityId) async {
    itemCalls.add(entityId);
    await beforeItems?.call(entityId);
    if (itemErrors[entityId] case final Object error) throw error;
    return items[entityId] ?? {'items': []};
  }

  @override
  Future<Object?> getNotifications() async {
    notificationCalls++;
    if (notificationsError != null) throw notificationsError!;
    return notifications;
  }

  @override
  Future<TodaySubscription> subscribeNotifications() async {
    final controller = StreamController<dynamic>();
    subscriptions.add(controller);
    return TodaySubscription(controller.stream, () async {
      cancelled++;
      await controller.close();
    });
  }

  @override
  Future<void> callService(
    String domain,
    String service,
    Map<String, dynamic> data, {
    String? entityId,
  }) async {
    serviceCalls.add((
      domain: domain,
      service: service,
      data: data,
      entityId: entityId,
    ));
    await onService?.call(domain, service, data, entityId);
  }
}

HaEntity todoEntity(String id, {int features = 117, String state = '1'}) =>
    HaEntity(
      entityId: id,
      state: state,
      attributes: {'supported_features': features, 'friendly_name': 'Shopping'},
    );

Map<String, dynamic> todoItem({
  String? uid = 'uid-one',
  String summary = 'Milk',
  String status = 'needs_action',
}) => {'uid': uid, 'summary': summary, 'status': status};

Map<String, dynamic> notification({
  String id = 'notice',
  String createdAt = '2026-09-05T10:00:00Z',
}) => {
  'notification_id': id,
  'message': 'Fixture only',
  'title': null,
  'created_at': createdAt,
};

Map<String, dynamic> calendarEvent({
  String from = '2026-09-05',
  String until = '2026-09-06',
  bool allDay = true,
}) => {
  'summary': 'Family',
  'start': {allDay ? 'date' : 'dateTime': from},
  'end': {allDay ? 'date' : 'dateTime': until},
};

Future<void> drain() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
