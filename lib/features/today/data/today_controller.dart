import 'dart:async';

import '../domain/today_models.dart';
import 'today_api.dart';
import 'today_repository.dart';

/// Account-scoped, memory-only state. Poll scheduling is owned by the provider;
/// this class coalesces reads and never invokes a mutation or queues one.
class TodayController {
  TodayController({required this.repository, DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final TodayRepository repository;
  final DateTime Function() _now;
  final _changes = StreamController<TodaySnapshot>.broadcast();
  final _locallyRead = <String, DateTime>{};
  final _pendingEvents = <Object?>[];
  TodaySnapshot? _snapshot;
  Future<void>? _refreshing;
  TodaySubscription? _remote;
  StreamSubscription<dynamic>? _events;
  int _subscriptionGeneration = 0;
  bool _subscribing = false;
  bool _foreground = true;
  bool _connected = false;
  bool _disposed = false;
  bool _overflowed = false;
  bool _refreshAgain = false;

  TodaySnapshot? get snapshot => _snapshot;
  Stream<TodaySnapshot> get changes => Stream.multi((sink) {
    final subscription = _changes.stream.listen(sink.add, onDone: sink.close);
    if (_snapshot != null) sink.add(_snapshot!);
    sink.onCancel = subscription.cancel;
  }, isBroadcast: true);

  Future<void> refresh({bool afterCurrent = false}) {
    if (_disposed || !_foreground) return Future.value();
    _ensureSubscription();
    if (_refreshing != null) {
      _refreshAgain = _refreshAgain || afterCurrent;
      return _refreshing!;
    }
    return _refreshing = _load().whenComplete(() {
      _refreshing = null;
      if (_refreshAgain) {
        _refreshAgain = false;
        unawaited(refresh());
      }
    });
  }

  Future<void> _load() async {
    _pendingEvents.clear();
    _overflowed = false;
    try {
      final value = await repository.load(previous: _snapshot);
      if (_disposed) return;
      var next = value;
      for (final event in _pendingEvents) {
        next = _mergeEvent(next, event);
      }
      if (_overflowed) {
        next = _notificationFailure(next, TodayFailure.invalidResponse);
      }
      _publish(next);
    } catch (error) {
      if (_disposed) return;
      final previous = _snapshot;
      final failure = classifyTodayFailure(error);
      final lists = [
        for (final list in previous?.todoLists ?? <TodayTodoList>[])
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
                failure,
                entityId: list.entityId,
              ),
            ),
          ),
      ];
      final calendars = [
        for (final calendar in previous?.calendars ?? <TodayCalendar>[])
          TodayCalendar(
            entityId: calendar.entityId,
            title: calendar.title,
            events: TodayRead(
              value: calendar.events.value,
              readAt: calendar.events.readAt,
              issue: TodayIssue(
                TodaySource.calendars,
                failure,
                entityId: calendar.entityId,
              ),
            ),
          ),
      ];
      final notificationIssue = TodayIssue(TodaySource.notifications, failure);
      _publish(
        TodaySnapshot(
          configured: true,
          refreshedAt: _now(),
          timeZone: previous?.timeZone,
          dayStart: previous?.dayStart,
          dayEnd: previous?.dayEnd,
          todoLists: List.unmodifiable(lists),
          calendars: List.unmodifiable(calendars),
          notifications: TodayRead(
            value: previous?.notifications.value,
            readAt: previous?.notifications.readAt,
            issue: notificationIssue,
          ),
          issues: [
            TodayIssue(TodaySource.configuration, failure),
            for (final list in lists) list.items.issue!,
            for (final calendar in calendars) calendar.events.issue!,
            notificationIssue,
          ],
        ),
      );
    } finally {
      _pendingEvents.clear();
    }
  }

  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (foreground) {
      _ensureSubscription();
    } else {
      _stopSubscription();
    }
  }

  void setConnected(bool connected) {
    if (_disposed || _connected == connected) return;
    _connected = connected;
    if (connected) {
      _ensureSubscription();
    } else {
      _stopSubscription();
    }
  }

  void _ensureSubscription() {
    if (_disposed ||
        !_foreground ||
        !_connected ||
        _remote != null ||
        _subscribing) {
      return;
    }
    final generation = ++_subscriptionGeneration;
    _subscribing = true;
    unawaited(() async {
      try {
        final remote = await repository.api.subscribeNotifications();
        if (_disposed || generation != _subscriptionGeneration) {
          await _cancelRemote(remote);
          return;
        }
        _remote = remote;
        _events = remote.events.listen(
          (event) {
            if (_disposed || generation != _subscriptionGeneration) return;
            if (_refreshing != null) {
              if (_pendingEvents.length < 16) {
                _pendingEvents.add(event);
              } else {
                _overflowed = true;
              }
            }
            final current = _snapshot;
            if (current != null) _publish(_mergeEvent(current, event));
          },
          onError: (Object error) {
            if (_disposed || generation != _subscriptionGeneration) return;
            final current = _snapshot;
            if (current != null) {
              _publish(
                _notificationFailure(current, classifyTodayFailure(error)),
              );
            }
            _stopSubscription();
          },
          onDone: () {
            if (!_disposed && generation == _subscriptionGeneration) {
              _stopSubscription();
            }
          },
        );
      } catch (_) {
        // A supported get may still work when a subscription is unavailable.
        // The next foreground poll retries only this read subscription.
      } finally {
        if (generation == _subscriptionGeneration) _subscribing = false;
      }
    }());
  }

  void _stopSubscription() {
    _subscriptionGeneration++;
    _subscribing = false;
    final events = _events;
    final remote = _remote;
    _events = null;
    _remote = null;
    if (events != null) unawaited(events.cancel());
    if (remote != null) unawaited(_cancelRemote(remote));
  }

  Future<void> _cancelRemote(TodaySubscription remote) async {
    try {
      await remote.cancel();
    } catch (_) {
      /* Transport may already be closed. */
    }
  }

  TodaySnapshot _mergeEvent(TodaySnapshot current, Object? event) {
    try {
      if (event is! Map<String, dynamic> || event['notifications'] is! Map) {
        throw const TodayException('invalid_notification_event');
      }
      final type = event['type'];
      if (!{'current', 'added', 'updated', 'removed'}.contains(type)) {
        throw const TodayException('invalid_notification_event');
      }
      final payload = Map<String, dynamic>.from(event['notifications'] as Map);
      final parsed = parseNotifications(payload.values.toList());
      if (parsed.any((item) => !payload.containsKey(item.id))) {
        throw const TodayException('invalid_notification_id');
      }
      final values = <String, TodayNotification>{
        if (type != 'current')
          for (final item
              in current.notifications.value ?? <TodayNotification>[])
            item.id: item,
      };
      for (final item in parsed) {
        if (type == 'removed') {
          values.remove(item.id);
        } else {
          values[item.id] = item;
        }
      }
      if (values.length > 5000) {
        throw const TodayException('too_many_notifications');
      }
      // A delta cannot establish a complete baseline after a failed first get.
      final hasBaseline =
          type == 'current' || current.notifications.value != null;
      if (!hasBaseline) return current;
      return current.withNotifications(
        TodayRead(value: List.unmodifiable(values.values), readAt: _now()),
        issues: List.unmodifiable(
          current.issues.where(
            (issue) => issue.source != TodaySource.notifications,
          ),
        ),
      );
    } catch (error) {
      return _notificationFailure(current, classifyTodayFailure(error));
    }
  }

  TodaySnapshot _notificationFailure(
    TodaySnapshot current,
    TodayFailure failure,
  ) {
    final issue = TodayIssue(TodaySource.notifications, failure);
    return current.withNotifications(
      TodayRead(
        value: current.notifications.value,
        readAt: current.notifications.readAt,
        issue: issue,
      ),
      issues: List.unmodifiable([
        ...current.issues.where(
          (entry) => entry.source != TodaySource.notifications,
        ),
        issue,
      ]),
    );
  }

  void markNotificationRead(String id) {
    if (_disposed) return;
    final current = _snapshot;
    if (current == null) return;
    for (final notification
        in current.notifications.value ?? <TodayNotification>[]) {
      if (notification.id == id) {
        _locallyRead[id] = notification.createdAt;
        break;
      }
    }
    _publish(current);
  }

  void _publish(TodaySnapshot value) {
    if (_disposed) return;
    final notifications = value.notifications.value;
    if (notifications != null) {
      final ids = notifications.map((item) => item.id).toSet();
      _locallyRead.removeWhere((id, _) => !ids.contains(id));
      value = value.withNotifications(
        TodayRead(
          value: List.unmodifiable(
            notifications.map(
              (item) => item.withRead(_locallyRead[item.id] == item.createdAt),
            ),
          ),
          issue: value.notifications.issue,
          readAt: value.notifications.readAt,
        ),
      );
    }
    _snapshot = value;
    _changes.add(value);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopSubscription();
    _locallyRead.clear();
    _pendingEvents.clear();
    repository.dispose();
    unawaited(_changes.close());
  }
}
