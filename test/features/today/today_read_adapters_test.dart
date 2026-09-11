import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/today/data/today_read_adapters.dart';
import 'package:larenor/features/today/domain/today_models.dart';

void main() {
  test('capability discovery accepts only the packaged read adapters', () {
    final capabilities = parseTodayReadCapabilities([
      'todo',
      'shopping_list',
      'calendar',
      'persistent_notification',
      'light',
    ]);

    expect(capabilities.todo, isTrue);
    expect(capabilities.shoppingList, isTrue);
    expect(capabilities.calendar, isTrue);
    expect(capabilities.persistentNotification, isTrue);
  });

  test('capability and legacy schemas are bounded and fail closed', () {
    for (final invalid in [
      null,
      {'todo': true},
      ['todo', 'todo'],
      ['Todo'],
      List.filled(4097, 'component'),
    ]) {
      expect(
        () => parseTodayReadCapabilities(invalid),
        throwsA(isA<TodayException>()),
      );
    }
    expect(
      () => parseLegacyShoppingItems([
        {'id': 'same', 'name': 'Milk', 'complete': false},
        {'id': 'same', 'name': 'Bread', 'complete': false},
      ]),
      throwsA(isA<TodayException>()),
    );
    expect(
      () => parseLegacyShoppingItems([
        {'id': 'one', 'name': 'Milk', 'complete': 'false'},
      ]),
      throwsA(isA<TodayException>()),
    );
  });

  test('legacy shopping items map to read-only todo values', () {
    final items = parseLegacyShoppingItems([
      {'id': 'one', 'name': 'Milk', 'complete': false},
      {'id': 'two', 'name': 'Bread', 'complete': true},
    ]);

    expect(items.first.uid, 'one');
    expect(items.first.summary, 'Milk');
    expect(items.first.status, TodayTodoStatus.needsAction);
    expect(items.last.status, TodayTodoStatus.completed);
  });
}
