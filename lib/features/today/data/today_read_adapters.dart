import '../domain/today_models.dart';

class TodayReadCapabilities {
  const TodayReadCapabilities({
    required this.todo,
    required this.shoppingList,
    required this.calendar,
    required this.persistentNotification,
  });

  final bool todo;
  final bool shoppingList;
  final bool calendar;
  final bool persistentNotification;
}

TodayReadCapabilities parseTodayReadCapabilities(Object? response) {
  if (response is! List || response.length > 4096) {
    throw const TodayException('invalid_components');
  }
  final components = <String>{};
  for (final value in response) {
    if (value is! String ||
        value.length > 128 ||
        !RegExp(r'^[a-z0-9_]+$').hasMatch(value) ||
        !components.add(value)) {
      throw const TodayException('invalid_components');
    }
  }
  return TodayReadCapabilities(
    todo: components.contains('todo'),
    shoppingList: components.contains('shopping_list'),
    calendar: components.contains('calendar'),
    persistentNotification: components.contains('persistent_notification'),
  );
}

List<TodayTodoItem> parseLegacyShoppingItems(Object? response) {
  if (response is! List || response.length > 5000) {
    throw const TodayException('invalid_shopping_list');
  }
  final ids = <String>{};
  return List.unmodifiable(
    response.map((value) {
      if (value is! Map<String, dynamic>) {
        throw const TodayException('invalid_shopping_item');
      }
      final id = _required(value['id'], maxLength: 1024);
      final name = _required(value['name'], maxLength: 4096);
      final complete = value['complete'];
      if (!ids.add(id) || complete is! bool) {
        throw const TodayException('invalid_shopping_item');
      }
      return TodayTodoItem(
        uid: id,
        summary: name,
        status: complete
            ? TodayTodoStatus.completed
            : TodayTodoStatus.needsAction,
      );
    }),
  );
}

String _required(Object? value, {required int maxLength}) {
  if (value is! String || value.isEmpty || value.length > maxLength) {
    throw const TodayException('invalid_shopping_item');
  }
  return value;
}
