import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ha_client/data/ha_api_exception.dart';
import 'package:larenor/features/health/data/action_controller.dart';
import 'package:larenor/features/health/data/action_receipt.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/today/data/today_actions.dart';
import 'package:larenor/features/today/data/today_repository.dart';
import 'package:larenor/features/today/domain/today_models.dart';

import 'fake_today_api.dart';

void main() {
  late FakeTodayApi api;
  late TodayRepository repository;
  late ActionController receipts;
  late TodayActions actions;
  late TodayTodoList list;
  setUp(() async {
    api = FakeTodayApi();
    repository = TodayRepository(api: api, now: () => DateTime.utc(2026, 9, 5));
    receipts = ActionController();
    actions = TodayActions(
      repository: repository,
      controller: receipts,
      readbackDelay: Duration.zero,
    );
    list = (await repository.load()).todoLists.single;
  });
  tearDown(() {
    repository.dispose();
    receipts.dispose();
  });

  test('same-title items update by stable UID, once, and confirm observed readback', () async {
    api.items['todo.shopping'] = {
      'items': [todoItem(), todoItem(uid: 'uid-two')],
    };
    api.onService = (_, _, data, _) async {
      expect(data, {'item': 'uid-one', 'status': 'completed'});
      api.items['todo.shopping'] = {
        'items': [todoItem(status: 'completed'), todoItem(uid: 'uid-two')],
      };
    };
    await actions.updateTodo(
      list,
      list.items.value!.single,
      status: TodayTodoStatus.completed,
    );
    expect(api.serviceCalls.single.entityId, 'todo.shopping');
    expect(receipts.receipts.single.status, ActionStatus.confirmed);
    expect(receipts.receipts.single.observedAt, isNotNull);
  });

  test(
    'UID colliding with another summary is rejected before mutation',
    () async {
      api.items['todo.shopping'] = {
        'items': [todoItem(uid: 'other', summary: 'uid-one'), todoItem()],
      };
      await expectLater(
        actions.updateTodo(
          list,
          list.items.value!.single,
          status: TodayTodoStatus.completed,
        ),
        throwsA(isA<ActionExecutionException>()),
      );
      expect(api.serviceCalls, isEmpty);
      expect(receipts.receipts.single.status, ActionStatus.failed);
    },
  );

  test(
    'missing UID, unsupported feature and ambiguous date validation never send',
    () async {
      await expectLater(
        actions.updateTodo(
          list,
          const TodayTodoItem(summary: 'No ID'),
          status: TodayTodoStatus.completed,
        ),
        throwsA(isA<TodayException>()),
      );
      final readonly = TodayTodoList(
        entityId: list.entityId,
        title: list.title,
        available: true,
        supportedFeatures: 0,
        items: list.items,
      );
      await expectLater(
        actions.addTodo(readonly, 'Bread'),
        throwsA(isA<TodayException>()),
      );
      await expectLater(
        actions.addTodo(
          list,
          'Bread',
          dueDate: '2026-09-05',
          dueAt: DateTime.utc(2026, 9, 5),
        ),
        throwsA(isA<TodayException>()),
      );
      await expectLater(
        actions.addTodo(list, 'Bread', dueDate: '2026-02-30'),
        throwsA(isA<TodayException>()),
      );
      expect(api.serviceCalls, isEmpty);
    },
  );

  test('add confirms only a new UID with requested fields', () async {
    api.onService = (_, service, data, _) async {
      expect(service, 'add_item');
      expect(data, {
        'item': 'Bread',
        'due_date': '2026-09-06',
        'description': 'Wholemeal',
      });
      api.items['todo.shopping'] = {
        'items': [
          todoItem(),
          {
            ...todoItem(uid: 'new', summary: 'Bread'),
            'due': '2026-09-06',
            'description': 'Wholemeal',
          },
        ],
      };
    };
    await actions.addTodo(
      list,
      '  Bread  ',
      dueDate: '2026-09-06',
      description: 'Wholemeal',
    );
    expect(api.serviceCalls, hasLength(1));
    expect(receipts.receipts.single.status, ActionStatus.confirmed);
  });

  test(
    'existing identical item cannot falsely confirm a silently ignored add',
    () async {
      await expectLater(
        actions.addTodo(list, 'Milk'),
        throwsA(isA<ActionExecutionException>()),
      );
      expect(api.serviceCalls, hasLength(1));
      expect(receipts.receipts.single.status, ActionStatus.unknown);
      expect(receipts.receipts.single.acceptedAt, isNotNull);
    },
  );

  test(
    'accepted but failed readback is unknown; action is never retried',
    () async {
      api.onService = (_, _, _, _) async {
        api.itemErrors['todo.shopping'] = TimeoutException('Fixture');
      };
      await expectLater(
        actions.updateTodo(
          list,
          list.items.value!.single,
          status: TodayTodoStatus.completed,
        ),
        throwsA(isA<ActionExecutionException>()),
      );
      expect(api.serviceCalls, hasLength(1));
      expect(receipts.receipts.single.status, ActionStatus.unknown);
    },
  );

  test('explicit HA permission rejection produces failed receipt', () async {
    api.onService = (_, _, _, _) async =>
        throw HaApiException('Fixture', statusCode: 403);
    await expectLater(
      actions.updateTodo(
        list,
        list.items.value!.single,
        status: TodayTodoStatus.completed,
      ),
      throwsA(isA<ActionExecutionException>()),
    );
    expect(receipts.receipts.single.status, ActionStatus.failed);
    expect(receipts.receipts.single.failure, ActionFailure.permission);
  });

  test(
    'duplicate action target is guarded even during read preflight',
    () async {
      final gate = Completer<void>();
      api.beforeItems = (_) => gate.future;
      final first = actions.updateTodo(
        list,
        list.items.value!.single,
        status: TodayTodoStatus.completed,
      );
      final expected = expectLater(
        first,
        throwsA(isA<ActionExecutionException>()),
      );
      await expectLater(
        actions.addTodo(list, 'Bread'),
        throwsA(isA<ActionInProgressException>()),
      );
      receipts.resetIntegration(IntegrationId.ha);
      await expected;
      gate.complete();
      await drain();
      expect(api.serviceCalls, isEmpty);
    },
  );

  test(
    'account disposal during preflight prevents an old server write',
    () async {
      final gate = Completer<void>();
      api.beforeItems = (_) => gate.future;
      final result = actions.updateTodo(
        list,
        list.items.value!.single,
        status: TodayTodoStatus.completed,
      );
      final expected = expectLater(
        result,
        throwsA(isA<ActionExecutionException>()),
      );
      repository.dispose();
      gate.complete();
      await expected;
      expect(api.serviceCalls, isEmpty);
    },
  );

  test(
    'dismiss mutates only explicit notification ID and confirms its absence',
    () async {
      api.onService = (domain, service, data, entityId) async {
        expect(domain, 'persistent_notification');
        expect(service, 'dismiss');
        expect(entityId, isNull);
        expect(data, {'notification_id': 'notice'});
        api.notifications = [];
      };
      await actions.dismissNotification('notice');
      expect(api.serviceCalls, hasLength(1));
      expect(receipts.receipts.single.status, ActionStatus.confirmed);
    },
  );

  test('cleared optional fields require readback of actual clearing', () async {
    api.onService = (_, _, data, _) async {
      expect(data, {'item': 'uid-one', 'due_date': null, 'description': null});
      api.items['todo.shopping'] = {
        'items': [todoItem()],
      };
    };
    await actions.updateTodo(
      list,
      list.items.value!.single,
      clearDue: true,
      clearDescription: true,
    );
    expect(receipts.receipts.single.status, ActionStatus.confirmed);
  });
}
