import 'dart:async';

import '../../ha_client/providers/ha_health_bindings.dart';
import '../../health/data/action_controller.dart';
import '../../health/data/action_receipt.dart';
import '../../health/data/integration_health.dart';
import '../domain/today_models.dart';
import 'today_repository.dart';
import 'today_timezone.dart';

class TodayActions {
  TodayActions({
    required this.repository,
    required this.controller,
    this.onChanged,
    this.readbackDelay = const Duration(milliseconds: 400),
  });
  final TodayRepository repository;
  final ActionController controller;
  final void Function()? onChanged;
  final Duration readbackDelay;

  Future<void> addTodo(
    TodayTodoList list,
    String summary, {
    String? dueDate,
    DateTime? dueAt,
    String? description,
  }) async {
    if (!list.canAdd) throw const TodayException('unsupported_add');
    final title = _summary(summary);
    final fields = _fields(
      list,
      dueDate: dueDate,
      dueAt: dueAt,
      description: description,
    );
    final beforeIds = <String>{};
    await _mutate<List<TodayTodoItem>>(
      target: list.entityId,
      action: 'todo.add_item',
      prepare: () async {
        final before = await repository.readTodoItems(list.entityId);
        beforeIds.addAll(before.map((item) => item.uid).whereType<String>());
      },
      send: () => repository.callService('todo', 'add_item', {
        'item': title,
        ...fields,
      }, entityId: list.entityId),
      read: () => repository.readTodoItems(list.entityId),
      confirms: (items) => items.any(
        (item) =>
            item.canIdentify &&
            !beforeIds.contains(item.uid) &&
            item.summary == title &&
            item.status == TodayTodoStatus.needsAction &&
            _matchesFields(item, fields),
      ),
    );
  }

  Future<void> updateTodo(
    TodayTodoList list,
    TodayTodoItem item, {
    String? summary,
    TodayTodoStatus? status,
    String? dueDate,
    DateTime? dueAt,
    String? description,
    bool clearDue = false,
    bool clearDescription = false,
  }) async {
    if (!list.canUpdate) throw const TodayException('unsupported_update');
    if (!item.canIdentify) throw const TodayException('missing_uid');
    if (status == TodayTodoStatus.unknown) {
      throw const TodayException('invalid_status');
    }
    final fields = _fields(
      list,
      dueDate: dueDate,
      dueAt: dueAt,
      description: description,
      clearDue: clearDue,
      clearDescription: clearDescription,
    );
    final title = summary == null ? null : _summary(summary);
    if (title != null) fields['rename'] = title;
    if (status != null) {
      fields['status'] = status == TodayTodoStatus.completed
          ? 'completed'
          : 'needs_action';
    }
    if (fields.isEmpty) throw const TodayException('empty_update');
    await _mutate<List<TodayTodoItem>>(
      target: list.entityId,
      action: 'todo.update_item',
      prepare: () async {
        final current = await repository.readTodoItems(list.entityId);
        if (!current.any((value) => value.uid == item.uid)) {
          throw const TodayException('item_missing');
        }
        // HA's helper accepts uid OR summary and chooses the first match.
        // Detect an existing summary collision before sending a UID update.
        if (current.any(
          (value) => value.uid != item.uid && value.summary == item.uid,
        )) {
          throw const TodayException('ambiguous_uid');
        }
      },
      send: () => repository.callService('todo', 'update_item', {
        'item': item.uid,
        ...fields,
      }, entityId: list.entityId),
      read: () => repository.readTodoItems(list.entityId),
      confirms: (items) => items.any(
        (value) =>
            value.uid == item.uid &&
            (title == null || value.summary == title) &&
            (status == null || value.status == status) &&
            _matchesFields(value, fields),
      ),
    );
  }

  Future<void> dismissNotification(String notificationId) async {
    requiredString(notificationId, maxLength: 1024);
    await _mutate<List<TodayNotification>>(
      target: 'persistent_notification.notifications',
      action: 'persistent_notification.dismiss',
      send: () => repository.callService('persistent_notification', 'dismiss', {
        'notification_id': notificationId,
      }),
      read: repository.readNotifications,
      confirms: (items) => !items.any((item) => item.id == notificationId),
    );
  }

  Future<void> _mutate<T>({
    required String target,
    required String action,
    Future<void> Function()? prepare,
    required Future<void> Function() send,
    required Future<T> Function() read,
    required bool Function(T) confirms,
  }) async {
    final observations = StreamController<T>();
    var active = true;
    var writeStarted = false;
    Future<void> readBack() async {
      try {
        for (var attempt = 0; attempt < 3 && active; attempt++) {
          final value = await read();
          if (!active) return;
          observations.add(value);
          if (confirms(value)) break;
          if (attempt < 2) await Future<void>.delayed(readbackDelay);
        }
      } catch (_) {
        if (active) {
          observations.addError(const TodayException('readback_failed'));
        }
      } finally {
        if (active) unawaited(observations.close());
      }
    }

    try {
      final receipt = await controller.execute<T>(
        key: ActionKey(
          integration: IntegrationId.ha,
          target: target,
          action: action,
        ),
        send: () async {
          await prepare?.call();
          if (!active) throw const TodayException('disposed');
          writeStarted = true;
          await send();
          // Only reads can be repeated. The mutation itself is sent once.
          unawaited(readBack());
        },
        observations: observations.stream,
        confirms: confirms,
        classifyFailure: (error) {
          if (!writeStarted) return ActionFailure.rejected;
          return classifyHaActionFailure(error);
        },
      );
      onChanged?.call();
      if (receipt.status == ActionStatus.failed ||
          receipt.status == ActionStatus.unknown) {
        throw ActionExecutionException(receipt);
      }
    } finally {
      active = false;
      unawaited(observations.close());
    }
  }

  String _summary(String value) {
    final summary = requiredString(value, maxLength: 4096).trim();
    if (summary.isEmpty) throw const TodayException('empty_summary');
    return summary;
  }

  Map<String, dynamic> _fields(
    TodayTodoList list, {
    String? dueDate,
    DateTime? dueAt,
    String? description,
    bool clearDue = false,
    bool clearDescription = false,
  }) {
    if ((dueDate != null && dueAt != null) ||
        (clearDue && (dueDate != null || dueAt != null))) {
      throw const TodayException('conflicting_due');
    }
    if (clearDescription && description != null) {
      throw const TodayException('conflicting_description');
    }
    final fields = <String, dynamic>{};
    if (dueDate != null) {
      if (!list.canSetDueDate) {
        throw const TodayException('unsupported_due_date');
      }
      parseDateOnly(dueDate);
      fields['due_date'] = dueDate;
    }
    if (dueAt != null) {
      if (!list.canSetDueTime) {
        throw const TodayException('unsupported_due_time');
      }
      fields['due_datetime'] = dueAt.toUtc().toIso8601String();
    }
    if (clearDue) {
      if (!list.canSetDueDate && !list.canSetDueTime) {
        throw const TodayException('unsupported_due_date');
      }
      fields[list.canSetDueDate ? 'due_date' : 'due_datetime'] = null;
    }
    if (description != null || clearDescription) {
      if (!list.canSetDescription) {
        throw const TodayException('unsupported_description');
      }
      fields['description'] = clearDescription
          ? null
          : requiredString(description, maxLength: 32768, allowEmpty: true);
    }
    return fields;
  }

  bool _matchesFields(TodayTodoItem item, Map<String, dynamic> fields) {
    if (fields.containsKey('description') &&
        item.description != fields['description']) {
      return false;
    }
    if (fields.containsKey('due_date') &&
        (item.dueDate != fields['due_date'] || item.dueAt != null)) {
      return false;
    }
    if (fields.containsKey('due_datetime')) {
      final expected = fields['due_datetime'];
      if (expected == null) return item.dueAt == null && item.dueDate == null;
      if (item.dueAt != parseTimestamp(expected as String) ||
          item.dueDate != null) {
        return false;
      }
    }
    return true;
  }
}
