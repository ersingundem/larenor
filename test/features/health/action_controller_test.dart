import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/health/data/action_controller.dart';
import 'package:larenor/features/health/data/action_receipt.dart';
import 'package:larenor/features/health/data/integration_health.dart';

ActionKey key([
  String target = 'light.lamp',
  String action = 'light.turn_on',
]) => ActionKey(integration: IntegrationId.ha, target: target, action: action);

void main() {
  late ActionController controller;
  setUp(() => controller = ActionController());
  tearDown(() => controller.dispose());

  test(
    'scene ends accepted, never confirmed from an unrelated timestamp',
    () async {
      final receipt = await controller.execute<void>(
        key: key('scene.night', 'scene.turn_on'),
        send: () async {},
      );
      expect(receipt.status, ActionStatus.accepted);
      expect(receipt.acceptedAt, isNotNull);
      expect(receipt.observedAt, isNull);
      expect(controller.hasPending, isFalse);
    },
  );

  test('ACK is accepted, and later matching observation confirms', () async {
    final states = StreamController<String>.broadcast(sync: true);
    addTearDown(states.close);
    final result = controller.execute<String>(
      key: key(),
      send: () async {},
      observations: states.stream,
      confirms: (value) => value == 'on',
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.receipts.first.status, ActionStatus.accepted);
    states.add('off');
    expect(controller.receipts.first.status, ActionStatus.accepted);
    states.add('on');
    expect((await result).status, ActionStatus.confirmed);
  });

  test(
    'fast observation before ACK is retained, unless subsequently reversed',
    () async {
      final states = StreamController<String>.broadcast(sync: true);
      final ack = Completer<void>();
      addTearDown(states.close);
      final result = controller.execute<String>(
        key: key(),
        send: () => ack.future,
        observations: states.stream,
        confirms: (value) => value == 'on',
      );
      states.add('on');
      states.add('off');
      ack.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.receipts.first.status, ActionStatus.accepted);
      states.add('on');
      expect((await result).status, ActionStatus.confirmed);
    },
  );

  test('matching fast update plus ACK confirms', () async {
    final states = StreamController<String>.broadcast(sync: true);
    addTearDown(states.close);
    final result = controller.execute<String>(
      key: key(),
      send: () async {
        states.add('on');
      },
      observations: states.stream,
      confirms: (value) => value == 'on',
    );
    expect((await result).status, ActionStatus.confirmed);
  });

  test('same entity blocks duplicate and opposing action but other target proceeds', () async {
    final ack = Completer<void>();
    var sends = 0;
    final first = controller.execute<void>(
      key: key(),
      send: () {
        sends++;
        return ack.future;
      },
    );
    expect(
      () => controller.execute<void>(
        key: key(),
        send: () async {
          sends++;
        },
      ),
      throwsA(isA<ActionInProgressException>()),
    );
    expect(
      () => controller.execute<void>(
        key: key('light.lamp', 'light.turn_off'),
        send: () async {
          sends++;
        },
      ),
      throwsA(isA<ActionInProgressException>()),
    );
    expect(
      (await controller.execute<void>(
        key: key('light.other'),
        send: () async {},
      )).status,
      ActionStatus.accepted,
    );
    expect(sends, 1);
    ack.complete();
    await first;
  });

  test(
    'lost acknowledgement is unknown and never retries or accepts late ACK',
    () async {
      final ack = Completer<void>();
      var sends = 0;
      final result = controller.execute<void>(
        key: key(),
        send: () {
          sends++;
          return ack.future;
        },
        acknowledgementTimeout: const Duration(milliseconds: 5),
      );
      expect((await result).status, ActionStatus.unknown);
      ack.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.receipts.first.status, ActionStatus.unknown);
      expect(sends, 1);
    },
  );

  test('ACK without expected observed state becomes unknown', () async {
    final states = StreamController<String>.broadcast();
    addTearDown(states.close);
    final receipt = await controller.execute<String>(
      key: key(),
      send: () async {},
      observations: states.stream,
      confirms: (value) => value == 'on',
      confirmationTimeout: const Duration(milliseconds: 5),
    );
    expect(receipt.status, ActionStatus.unknown);
    expect(receipt.acceptedAt, isNotNull);
    expect(receipt.failure, ActionFailure.timeout);
  });

  test(
    'observation channel loss retains acceptance but reports unknown result',
    () async {
      final states = StreamController<String>.broadcast();
      final result = controller.execute<String>(
        key: key(),
        send: () async {},
        observations: states.stream,
        confirms: (value) => value == 'on',
      );
      await Future<void>.delayed(Duration.zero);
      await states.close();
      final receipt = await result;
      expect(receipt.status, ActionStatus.unknown);
      expect(receipt.failure, ActionFailure.observationLost);
      expect(receipt.acceptedAt, isNotNull);
    },
  );

  test(
    'explicit rejection fails; arbitrary provider text is not retained',
    () async {
      final receipt = await controller.execute<void>(
        key: key(),
        send: () async => throw StateError('secret=not-for-ui'),
        classifyFailure: (_) => ActionFailure.permission,
      );
      expect(receipt.status, ActionStatus.failed);
      expect(receipt.failure, ActionFailure.permission);
      expect(
        ActionExecutionException(receipt).toString(),
        isNot(contains('secret')),
      );
      final uncertain = await controller.execute<void>(
        key: key(),
        send: () async => throw StateError('secret=not-for-ui'),
      );
      expect(uncertain.status, ActionStatus.unknown);
    },
  );

  test('dispose completes pending receipts without writing again', () async {
    final ack = Completer<void>();
    final result = controller.execute<void>(key: key(), send: () => ack.future);
    controller.dispose();
    expect((await result).failure, ActionFailure.disposed);
    ack.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.hasPending, isFalse);
  });

  test('receipt history bounded and immutable', () async {
    final bounded = ActionController(historyLimit: 2);
    addTearDown(bounded.dispose);
    for (var i = 0; i < 4; i++) {
      await bounded.execute<void>(key: key(), send: () async {});
    }
    expect(bounded.receipts.map((receipt) => receipt.id), [4, 3]);
    expect(() => bounded.receipts.clear(), throwsUnsupportedError);
  });
}
