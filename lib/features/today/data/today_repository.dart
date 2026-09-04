import 'dart:async';

import 'package:http/http.dart' as http;

import '../../ha_client/data/ha_api_exception.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../domain/today_models.dart';
import 'today_api.dart';
import 'today_timezone.dart';

class TodayRepository {
  TodayRepository({required this.api, DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final TodayApi api;
  final DateTime Function() _now;
  bool _disposed = false;

  Future<TodaySnapshot> load({TodaySnapshot? previous}) async {
    _checkActive();
    final results = await Future.wait([
      _read(TodaySource.configuration, api.getConfig),
      _read(TodaySource.todos, api.getEntities),
      _read(TodaySource.calendars, api.getCalendars),
      _read(
        TodaySource.notifications,
        readNotifications,
        previous: previous?.notifications,
      ),
    ]);
    _checkActive();
    final config = results[0] as TodayRead<Map<String, dynamic>>;
    final entities = results[1] as TodayRead<List<HaEntity>>;
    final calendarIndex = results[2] as TodayRead<List<Map<String, dynamic>>>;
    final notifications = results[3] as TodayRead<List<TodayNotification>>;
    final issues = <TodayIssue>[
      for (final result in results)
        if (result.issue != null) result.issue!,
    ];
    TodayTimeZone? zone;
    ({DateTime start, DateTime end})? day;
    try {
      final name = config.value?['time_zone'];
      if (name is! String) throw const TodayException('missing_timezone');
      zone = TodayTimeZone(name);
      day = zone.dayRange(_now());
    } catch (_) {
      if (config.issue == null) {
        issues.add(
          const TodayIssue(
            TodaySource.configuration,
            TodayFailure.invalidResponse,
          ),
        );
      }
    }

    final oldLists = {
      for (final list in previous?.todoLists ?? <TodayTodoList>[])
        list.entityId: list,
    };
    final listEntities = (entities.value ?? const <HaEntity>[])
        .where((entity) => entity.domain == 'todo')
        .toList();
    if (listEntities.length > 100) {
      issues.add(
        const TodayIssue(TodaySource.todos, TodayFailure.invalidResponse),
      );
    }
    final lists = entities.issue == null
        ? await _mapBounded(listEntities.take(100).toList(), (entity) async {
            final available = !{
              'unavailable',
              'unknown',
            }.contains(entity.state);
            final features = entity.attributes['supported_features'];
            final items = available
                ? await _read(
                    TodaySource.todos,
                    () => readTodoItems(entity.entityId),
                    entityId: entity.entityId,
                    previous: oldLists[entity.entityId]?.items,
                  )
                : TodayRead<List<TodayTodoItem>>(
                    value: oldLists[entity.entityId]?.items.value,
                    readAt: oldLists[entity.entityId]?.items.readAt,
                    issue: TodayIssue(
                      TodaySource.todos,
                      TodayFailure.unavailable,
                      entityId: entity.entityId,
                    ),
                  );
            final name = entity.attributes['friendly_name'];
            return TodayTodoList(
              entityId: entity.entityId,
              title: name is String && name.length <= 4096
                  ? name
                  : entity.entityId,
              supportedFeatures: features is int && features >= 0
                  ? features
                  : 0,
              available: available,
              items: items,
            );
          })
        : [
            for (final list in oldLists.values)
              TodayTodoList(
                entityId: list.entityId,
                title: list.title,
                supportedFeatures: list.supportedFeatures,
                available: false,
                items: TodayRead(
                  value: list.items.value,
                  readAt: list.items.readAt,
                  issue: TodayIssue(
                    TodaySource.todos,
                    entities.issue!.failure,
                    entityId: list.entityId,
                  ),
                ),
              ),
          ];

    final oldCalendars = {
      for (final calendar in previous?.calendars ?? <TodayCalendar>[])
        calendar.entityId: calendar,
    };
    final metadata = <({String id, String title})>[];
    TodayIssue? catalogIssue = calendarIndex.issue;
    if (calendarIndex.value != null) {
      try {
        if (calendarIndex.value!.length > 100) {
          throw const TodayException('too_many_calendars');
        }
        final ids = <String>{};
        for (final entry in calendarIndex.value!) {
          final id = requiredString(entry['entity_id'], maxLength: 256);
          if (!RegExp(r'^calendar\.[a-z0-9_]+$').hasMatch(id) || !ids.add(id)) {
            throw const TodayException('invalid_calendar');
          }
          metadata.add((id: id, title: optionalString(entry['name']) ?? id));
        }
      } catch (_) {
        metadata.clear();
        catalogIssue = const TodayIssue(
          TodaySource.calendars,
          TodayFailure.invalidResponse,
        );
        issues.add(catalogIssue);
      }
    }
    if (catalogIssue != null) {
      metadata.addAll(
        oldCalendars.values.map(
          (entry) => (id: entry.entityId, title: entry.title),
        ),
      );
    }
    final selectedZone = zone;
    final selectedDay = day;
    final calendars = await _mapBounded(metadata, (entry) async {
      final old = oldCalendars[entry.id]?.events;
      final TodayRead<List<TodayCalendarEvent>> events;
      if (selectedZone == null || selectedDay == null || catalogIssue != null) {
        events = TodayRead(
          value: old?.value,
          readAt: old?.readAt,
          issue: TodayIssue(
            TodaySource.calendars,
            catalogIssue?.failure ?? TodayFailure.invalidResponse,
            entityId: entry.id,
          ),
        );
      } else {
        events = await _read(
          TodaySource.calendars,
          () async =>
              parseCalendarEvents(
                    await api.getCalendarEvents(
                      entry.id,
                      selectedDay.start,
                      selectedDay.end,
                    ),
                    selectedZone,
                  )
                  .where(
                    (event) =>
                        event.start.isBefore(selectedDay.end) &&
                        event.end.isAfter(selectedDay.start),
                  )
                  .toList(growable: false),
          entityId: entry.id,
          previous: old,
        );
      }
      return TodayCalendar(
        entityId: entry.id,
        title: entry.title,
        events: events,
      );
    });
    _checkActive();
    issues.addAll([
      for (final list in lists)
        if (list.items.issue != null) list.items.issue!,
      for (final calendar in calendars)
        if (calendar.events.issue != null) calendar.events.issue!,
    ]);
    return TodaySnapshot(
      configured: true,
      refreshedAt: _now(),
      timeZone: zone?.name,
      dayStart: day?.start,
      dayEnd: day?.end,
      todoLists: List.unmodifiable(lists),
      calendars: List.unmodifiable(calendars),
      notifications: notifications,
      issues: List.unmodifiable(issues),
    );
  }

  Future<List<TodayTodoItem>> readTodoItems(String entityId) async {
    _checkActive();
    if (!RegExp(r'^todo\.[a-z0-9_]+$').hasMatch(entityId)) {
      throw const TodayException('invalid_entity');
    }
    return parseTodoItems(await api.getTodoItems(entityId));
  }

  Future<List<TodayNotification>> readNotifications() async {
    _checkActive();
    return parseNotifications(await api.getNotifications());
  }

  Future<void> callService(
    String domain,
    String service,
    Map<String, dynamic> data, {
    String? entityId,
  }) {
    _checkActive();
    return api.callService(domain, service, data, entityId: entityId);
  }

  Future<TodayRead<T>> _read<T>(
    TodaySource source,
    Future<T> Function() read, {
    String? entityId,
    TodayRead<T>? previous,
  }) async {
    _checkActive();
    try {
      final value = await read();
      return TodayRead(value: value, readAt: _now());
    } catch (error) {
      return TodayRead(
        value: previous?.value,
        readAt: previous?.readAt,
        issue: TodayIssue(
          source,
          classifyTodayFailure(error),
          entityId: entityId,
        ),
      );
    }
  }

  Future<List<R>> _mapBounded<T, R>(
    List<T> entries,
    Future<R> Function(T) read,
  ) async {
    final values = List<R?>.filled(entries.length, null);
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < entries.length) {
        _checkActive();
        final index = cursor++;
        values[index] = await read(entries[index]);
      }
    }

    await Future.wait([
      for (var i = 0; i < entries.length.clamp(0, 4); i++) worker(),
    ]);
    return List<R>.unmodifiable(values.cast<R>());
  }

  void _checkActive() {
    if (_disposed) throw const TodayException('disposed');
  }

  void dispose() => _disposed = true;
}

List<TodayTodoItem> parseTodoItems(Object? response) {
  if (response is! Map<String, dynamic> || response['items'] is! List) {
    throw const TodayException('invalid_todos');
  }
  final items = response['items'] as List;
  if (items.length > 5000) throw const TodayException('too_many_items');
  final ids = <String>{};
  return List.unmodifiable(
    items.map((value) {
      if (value is! Map<String, dynamic>) {
        throw const TodayException('invalid_item');
      }
      final uid = optionalString(value['uid'], maxLength: 1024);
      if (uid != null && !ids.add(uid)) {
        throw const TodayException('duplicate_uid');
      }
      final due = optionalString(value['due'], maxLength: 100);
      String? dueDate;
      DateTime? dueAt;
      if (due != null) {
        if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(due)) {
          parseDateOnly(due);
          dueDate = due;
        } else {
          dueAt = parseTimestamp(due);
        }
      }
      final completed = optionalString(value['completed'], maxLength: 100);
      return TodayTodoItem(
        uid: uid,
        summary: optionalString(value['summary']),
        status: switch (value['status']) {
          'needs_action' => TodayTodoStatus.needsAction,
          'completed' => TodayTodoStatus.completed,
          null => TodayTodoStatus.unknown,
          final String _ => TodayTodoStatus.unknown,
          _ => throw const TodayException('invalid_status'),
        },
        dueDate: dueDate,
        dueAt: dueAt,
        description: optionalString(value['description'], maxLength: 32768),
        completedAt: completed == null ? null : parseTimestamp(completed),
      );
    }),
  );
}

List<TodayNotification> parseNotifications(Object? response) {
  if (response is! List || response.length > 5000) {
    throw const TodayException('invalid_notifications');
  }
  final ids = <String>{};
  return List.unmodifiable(
    response.map((value) {
      if (value is! Map<String, dynamic>) {
        throw const TodayException('invalid_notification');
      }
      final id = requiredString(value['notification_id'], maxLength: 1024);
      if (!ids.add(id)) throw const TodayException('duplicate_notification');
      return TodayNotification(
        id: id,
        message: requiredString(
          value['message'],
          maxLength: 32768,
          allowEmpty: true,
        ),
        title: optionalString(value['title']),
        createdAt: parseTimestamp(
          requiredString(value['created_at'], maxLength: 100),
        ),
      );
    }),
  );
}

List<TodayCalendarEvent> parseCalendarEvents(
  List<Map<String, dynamic>> values,
  TodayTimeZone zone,
) {
  if (values.length > 5000) throw const TodayException('too_many_events');
  final events = values.map((value) {
    final start = value['start'];
    final end = value['end'];
    if (start is! Map<String, dynamic> || end is! Map<String, dynamic>) {
      throw const TodayException('invalid_calendar_time');
    }
    final allDay = start.containsKey('date');
    if (allDay != end.containsKey('date') ||
        start.containsKey('date') == start.containsKey('dateTime') ||
        end.containsKey('date') == end.containsKey('dateTime')) {
      throw const TodayException('mixed_calendar_time');
    }
    final startText = requiredString(
      start[allDay ? 'date' : 'dateTime'],
      maxLength: 100,
    );
    final endText = requiredString(
      end[allDay ? 'date' : 'dateTime'],
      maxLength: 100,
    );
    final from = allDay
        ? zone.date(startText)
        : zone.local(parseTimestamp(startText));
    final until = allDay
        ? zone.date(endText)
        : zone.local(parseTimestamp(endText));
    if (!until.isAfter(from)) {
      throw const TodayException('invalid_calendar_range');
    }
    return TodayCalendarEvent(
      uid: optionalString(value['uid'], maxLength: 1024),
      title: requiredString(value['summary'], allowEmpty: true),
      start: from,
      end: until,
      allDay: allDay,
      startDate: allDay ? startText : null,
      endDate: allDay ? endText : null,
      description: optionalString(value['description'], maxLength: 32768),
      location: optionalString(value['location']),
    );
  }).toList();
  events.sort((a, b) => a.start.compareTo(b.start));
  return List.unmodifiable(events);
}

TodayFailure classifyTodayFailure(Object error) {
  if (error is TimeoutException) return TodayFailure.timeout;
  if (error is http.ClientException) return TodayFailure.network;
  if (error is HaApiException) {
    if (error.statusCode == 401) return TodayFailure.authentication;
    if (error.statusCode == 403 ||
        error.code == 'unauthorized' ||
        error.code == 'forbidden') {
      return TodayFailure.permission;
    }
    if (error.code == 'timeout') return TodayFailure.timeout;
    if ({'not_connected', 'connection_error', 'closed'}.contains(error.code)) {
      return TodayFailure.network;
    }
    if (error.statusCode == 404 ||
        {'unknown_command', 'not_supported'}.contains(error.code)) {
      return TodayFailure.unsupported;
    }
  }
  return TodayFailure.invalidResponse;
}

String? optionalString(Object? value, {int maxLength = 4096}) {
  if (value == null) return null;
  if (value is! String || value.length > maxLength) {
    throw const TodayException('invalid_text');
  }
  return value;
}

String requiredString(
  Object? value, {
  int maxLength = 4096,
  bool allowEmpty = false,
}) {
  final text = optionalString(value, maxLength: maxLength);
  if (text == null || (!allowEmpty && text.isEmpty)) {
    throw const TodayException('invalid_text');
  }
  return text;
}
