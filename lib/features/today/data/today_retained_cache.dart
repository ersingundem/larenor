import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/home_data_scope.dart';
import '../../auth/data/ha_connection_config.dart';
import '../domain/today_models.dart';
import 'today_timezone.dart';

abstract interface class TodayRetainedBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class SecureTodayRetainedBackend implements TodayRetainedBackend {
  SecureTodayRetainedBackend([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

final class TodayRetainedException implements Exception {
  const TodayRetainedException(this.code);
  final String code;

  @override
  String toString() => 'The saved Today summary is unavailable.';
}

Never _fail(String code) => throw TodayRetainedException(code);

/// A one-way storage identity. Raw endpoints, account tokens and Core identity
/// fields never appear in keys, logs or the encrypted record.
final class TodayRetainedScope {
  TodayRetainedScope._(this._fingerprint);

  factory TodayRetainedScope.direct(HaConnectionConfig config) {
    final endpoint = HaConnectionConfig.normalizeBaseUrl(config.baseUrl);
    if (endpoint.isEmpty || endpoint.length > 2048 || config.token.isEmpty) {
      _fail('invalid_scope');
    }
    return TodayRetainedScope._(
      sha256
          .convert(
            utf8.encode(
              jsonEncode([
                'today-retained-v1',
                'direct',
                endpoint,
                config.token,
              ]),
            ),
          )
          .toString(),
    );
  }

  factory TodayRetainedScope.core(HomeDataScope scope) => TodayRetainedScope._(
    sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'today-retained-v1',
              'core',
              scope.coreId,
              scope.homeId,
              scope.userId,
            ]),
          ),
        )
        .toString(),
  );

  final String _fingerprint;
  String get storageKey => 'today_retained_v1_$_fingerprint';

  @override
  String toString() => 'TodayRetainedScope';
}

abstract interface class TodayRetainedPersistence {
  Future<TodaySnapshot?> read(
    TodayRetainedScope scope, {
    required bool Function() isCurrent,
  });
  Future<void> write(
    TodayRetainedScope scope,
    TodaySnapshot snapshot, {
    required bool Function() isCurrent,
  });
}

/// A bounded encrypted cache. It is display evidence only and never grants HA
/// authority; restored reads are marked stale so every mutation stays closed.
final class TodayRetainedStore implements TodayRetainedPersistence {
  TodayRetainedStore({
    TodayRetainedBackend? backend,
    DateTime Function()? clock,
  }) : _backend = backend ?? SecureTodayRetainedBackend(),
       _clock = clock ?? DateTime.now;

  static const maximumRawBytes = 256 * 1024;
  final TodayRetainedBackend _backend;
  final DateTime Function() _clock;

  void Function() _guard(bool Function() isCurrent) {
    var retired = false;
    return () {
      try {
        if (!retired && isCurrent()) return;
      } catch (_) {
        // A failed owner callback cannot authorize cache disclosure.
      }
      retired = true;
      _fail('retired');
    };
  }

  @override
  Future<TodaySnapshot?> read(
    TodayRetainedScope scope, {
    required bool Function() isCurrent,
  }) async {
    final check = _guard(isCurrent);
    check();
    String? raw;
    try {
      raw = await _backend.read(scope.storageKey);
      check();
      if (raw == null) return null;
      if (utf8.encode(raw).length > maximumRawBytes) _fail('invalid_record');
      final decoded = _TodaySnapshotCodec.decode(raw, scope._fingerprint);
      final now = _clock().toUtc();
      final start = decoded.dayStart?.toUtc();
      final end = decoded.dayEnd?.toUtc();
      if (decoded.refreshedAt.toUtc().isAfter(
            now.add(const Duration(minutes: 5)),
          ) ||
          now.difference(decoded.refreshedAt.toUtc()) >
              const Duration(hours: 36) ||
          start == null ||
          end == null ||
          !start.isBefore(end) ||
          now.isBefore(start) ||
          !now.isBefore(end)) {
        _fail('expired_record');
      }
      return decoded.asRetained();
    } on TodayRetainedException catch (error) {
      if (error.code == 'retired') rethrow;
      await _discard(scope.storageKey, check);
      return null;
    } catch (_) {
      check();
      await _discard(scope.storageKey, check);
      return null;
    }
  }

  Future<void> _discard(String key, void Function() check) async {
    check();
    try {
      await _backend.delete(key);
      check();
    } catch (_) {
      check();
      // An unreadable entry remains untrusted; cleanup can be retried later.
    }
  }

  @override
  Future<void> write(
    TodayRetainedScope scope,
    TodaySnapshot snapshot, {
    required bool Function() isCurrent,
  }) async {
    final check = _guard(isCurrent);
    check();
    if (!snapshot.configured || snapshot.retained) return;
    final raw = _TodaySnapshotCodec.encode(snapshot, scope._fingerprint);
    if (utf8.encode(raw).length > maximumRawBytes) return;
    try {
      await _backend.write(scope.storageKey, raw);
      check();
    } on TodayRetainedException {
      rethrow;
    } catch (_) {
      check();
      throw const TodayRetainedException('write_failed');
    }
  }
}

final class _TodaySnapshotCodec {
  static const _keys = {
    'version',
    'scope',
    'configured',
    'refreshedAt',
    'timeZone',
    'dayStart',
    'dayEnd',
    'todoLists',
    'calendars',
    'notifications',
    'issues',
  };

  static String encode(TodaySnapshot value, String scope) => jsonEncode({
    'version': 1,
    'scope': scope,
    'configured': value.configured,
    'refreshedAt': _date(value.refreshedAt),
    'timeZone': value.timeZone,
    'dayStart': _date(value.dayStart),
    'dayEnd': _date(value.dayEnd),
    'todoLists': value.todoLists.map(_todoList).toList(growable: false),
    'calendars': value.calendars.map(_calendar).toList(growable: false),
    'notifications': _read(
      value.notifications,
      (items) => items.map(_notification).toList(growable: false),
    ),
    'issues': value.issues.map(_issue).toList(growable: false),
  });

  static TodaySnapshot decode(String raw, String scope) {
    try {
      final root = _map(jsonDecode(raw), _keys);
      if (root['version'] != 1 || root['scope'] != scope) {
        _fail('invalid_record');
      }
      final timeZone = _optionalText(root['timeZone'], 128);
      if (timeZone != null) TodayTimeZone(timeZone);
      final lists = _list(root['todoLists'], 100).map(_decodeTodoList).toList();
      final calendars = _list(
        root['calendars'],
        100,
      ).map(_decodeCalendar).toList();
      final notifications = _decodeRead<List<TodayNotification>>(
        root['notifications'],
        (value) => _list(value, 5000).map(_decodeNotification).toList(),
      );
      return TodaySnapshot(
        configured: _bool(root['configured']),
        refreshedAt: _requiredDate(root['refreshedAt']),
        timeZone: timeZone,
        dayStart: _optionalDate(root['dayStart']),
        dayEnd: _optionalDate(root['dayEnd']),
        todoLists: List.unmodifiable(lists),
        calendars: List.unmodifiable(calendars),
        notifications: notifications,
        issues: List.unmodifiable(_list(root['issues'], 512).map(_decodeIssue)),
      );
    } on TodayRetainedException {
      rethrow;
    } catch (_) {
      _fail('invalid_record');
    }
  }

  static Map<String, Object?> _todoList(TodayTodoList value) => {
    'entityId': value.entityId,
    'title': value.title,
    'supportedFeatures': value.supportedFeatures,
    'available': value.available,
    'items': _read(
      value.items,
      (items) => items.map(_todoItem).toList(growable: false),
    ),
  };

  static Map<String, Object?> _todoItem(TodayTodoItem value) => {
    'uid': value.uid,
    'summary': value.summary,
    'status': value.status.name,
    'dueDate': value.dueDate,
    'dueAt': _date(value.dueAt),
    'description': value.description,
    'completedAt': _date(value.completedAt),
  };

  static Map<String, Object?> _calendar(TodayCalendar value) => {
    'entityId': value.entityId,
    'title': value.title,
    'events': _read(
      value.events,
      (events) => events.map(_event).toList(growable: false),
    ),
  };

  static Map<String, Object?> _event(TodayCalendarEvent value) => {
    'uid': value.uid,
    'title': value.title,
    'start': _date(value.start),
    'end': _date(value.end),
    'allDay': value.allDay,
    'startDate': value.startDate,
    'endDate': value.endDate,
    'description': value.description,
    'location': value.location,
  };

  static Map<String, Object?> _notification(TodayNotification value) => {
    'id': value.id,
    'message': value.message,
    'createdAt': _date(value.createdAt),
    'title': value.title,
    'isRead': value.isRead,
  };

  static Map<String, Object?> _issue(TodayIssue value) => {
    'source': value.source.name,
    'failure': value.failure.name,
    'entityId': value.entityId,
  };

  static Map<String, Object?> _read<T>(
    TodayRead<T> value,
    Object? Function(T value) encode,
  ) => {
    'value': value.value == null ? null : encode(value.value as T),
    'issue': value.issue == null ? null : _issue(value.issue!),
    'readAt': _date(value.readAt),
  };

  static TodayTodoList _decodeTodoList(Object? raw) {
    final value = _map(raw, {
      'entityId',
      'title',
      'supportedFeatures',
      'available',
      'items',
    });
    final features = value['supportedFeatures'];
    if (features is! int || features < 0 || features > 0x7fffffff) {
      _fail('invalid_record');
    }
    return TodayTodoList(
      entityId: _text(value['entityId'], 256),
      title: _text(value['title'], 4096),
      supportedFeatures: features,
      available: _bool(value['available']),
      items: _decodeRead<List<TodayTodoItem>>(
        value['items'],
        (raw) => _list(raw, 500).map(_decodeTodoItem).toList(),
      ),
    );
  }

  static TodayTodoItem _decodeTodoItem(Object? raw) {
    final value = _map(raw, {
      'uid',
      'summary',
      'status',
      'dueDate',
      'dueAt',
      'description',
      'completedAt',
    });
    return TodayTodoItem(
      uid: _optionalText(value['uid'], 4096),
      summary: _optionalText(value['summary'], 4096),
      status: _enum(TodayTodoStatus.values, value['status']),
      dueDate: _optionalText(value['dueDate'], 10),
      dueAt: _optionalDate(value['dueAt']),
      description: _optionalText(value['description'], 4096),
      completedAt: _optionalDate(value['completedAt']),
    );
  }

  static TodayCalendar _decodeCalendar(Object? raw) {
    final value = _map(raw, {'entityId', 'title', 'events'});
    return TodayCalendar(
      entityId: _text(value['entityId'], 256),
      title: _text(value['title'], 4096),
      events: _decodeRead<List<TodayCalendarEvent>>(
        value['events'],
        (raw) => _list(raw, 500).map(_decodeEvent).toList(),
      ),
    );
  }

  static TodayCalendarEvent _decodeEvent(Object? raw) {
    final value = _map(raw, {
      'uid',
      'title',
      'start',
      'end',
      'allDay',
      'startDate',
      'endDate',
      'description',
      'location',
    });
    final start = _requiredDate(value['start']);
    final end = _requiredDate(value['end']);
    final allDay = _bool(value['allDay']);
    final startDate = _optionalText(value['startDate'], 10);
    final endDate = _optionalText(value['endDate'], 10);
    if (!end.isAfter(start) ||
        (allDay && (startDate == null || endDate == null)) ||
        (!allDay && (startDate != null || endDate != null))) {
      _fail('invalid_record');
    }
    if (allDay) {
      final first = parseDateOnly(startDate!);
      final last = parseDateOnly(endDate!);
      if (!last.isAfter(first)) _fail('invalid_record');
    }
    return TodayCalendarEvent(
      uid: _optionalText(value['uid'], 4096),
      title: _text(value['title'], 4096),
      start: start,
      end: end,
      allDay: allDay,
      startDate: startDate,
      endDate: endDate,
      description: _optionalText(value['description'], 4096),
      location: _optionalText(value['location'], 4096),
    );
  }

  static TodayNotification _decodeNotification(Object? raw) {
    final value = _map(raw, {'id', 'message', 'createdAt', 'title', 'isRead'});
    return TodayNotification(
      id: _text(value['id'], 4096),
      message: _text(value['message'], 4096),
      createdAt: _requiredDate(value['createdAt']),
      title: _optionalText(value['title'], 4096),
      isRead: _bool(value['isRead']),
    );
  }

  static TodayIssue _decodeIssue(Object? raw) {
    final value = _map(raw, {'source', 'failure', 'entityId'});
    return TodayIssue(
      _enum(TodaySource.values, value['source']),
      _enum(TodayFailure.values, value['failure']),
      entityId: _optionalText(value['entityId'], 256),
    );
  }

  static TodayRead<T> _decodeRead<T>(
    Object? raw,
    T Function(Object? value) decode,
  ) {
    final value = _map(raw, {'value', 'issue', 'readAt'});
    return TodayRead(
      value: value['value'] == null ? null : decode(value['value']),
      issue: value['issue'] == null ? null : _decodeIssue(value['issue']),
      readAt: _optionalDate(value['readAt']),
    );
  }

  static Map<String, dynamic> _map(Object? raw, Set<String> keys) {
    if (raw is! Map<String, dynamic> ||
        raw.length != keys.length ||
        raw.keys.toSet().difference(keys).isNotEmpty) {
      _fail('invalid_record');
    }
    return raw;
  }

  static List<Object?> _list(Object? raw, int maximum) {
    if (raw is! List || raw.length > maximum) _fail('invalid_record');
    return raw.cast<Object?>();
  }

  static bool _bool(Object? value) {
    if (value is! bool) _fail('invalid_record');
    return value;
  }

  static String _text(Object? value, int maximum) {
    if (value is! String ||
        value.isEmpty ||
        value.length > maximum ||
        value.contains(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'))) {
      _fail('invalid_record');
    }
    return value;
  }

  static String? _optionalText(Object? value, int maximum) =>
      value == null ? null : _text(value, maximum);

  static DateTime? _optionalDate(Object? value) =>
      value == null ? null : _requiredDate(value);

  static DateTime _requiredDate(Object? value) {
    if (value is! String || value.length > 40) _fail('invalid_record');
    final parsed = DateTime.tryParse(value)?.toUtc();
    if (parsed == null || parsed.toIso8601String() != value) {
      _fail('invalid_record');
    }
    return parsed;
  }

  static T _enum<T extends Enum>(List<T> values, Object? raw) {
    if (raw is! String) _fail('invalid_record');
    for (final value in values) {
      if (value.name == raw) return value;
    }
    _fail('invalid_record');
  }

  static String? _date(DateTime? value) => value?.toUtc().toIso8601String();
}
