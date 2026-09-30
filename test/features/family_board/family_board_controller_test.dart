import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/family_board/data/family_board_controller.dart';
import 'package:larenor/features/family_board/domain/family_board_models.dart';

const core = '11111111111111111111111111111111';
const home = '22222222222222222222222222222222';
const boardId = '33333333333333333333333333333333';
const account = '44444444444444444444444444444444';
const session = '55555555555555555555555555555555';
const cardId = '66666666666666666666666666666666';

FamilyBoardBinding binding({int memberRevision = 1, bool active = true}) =>
    FamilyBoardBinding(
      coreId: core,
      homeId: home,
      homeRevision: 7,
      boardId: boardId,
      accountId: account,
      accountRevision: 3,
      memberRevision: memberRevision,
      sessionFamilyId: session,
      routeRevision: 11,
      lifecycleRevision: 13,
      active: active,
      canWrite: true,
    );

Map<String, Object?> snapshotJson({
  int revision = 1,
  String text = 'Film gecesi',
}) => {
  'schemaVersion': 1,
  'authority': {
    'schemaVersion': 1,
    'coreId': core,
    'homeId': home,
    'homeRevision': 7,
    'boardId': boardId,
    'accountId': account,
    'accountRevision': 3,
    'memberRevision': 1,
    'sessionFamilyId': session,
    'role': 'admin',
    'canRead': true,
    'canWrite': true,
    'active': true,
  },
  'boardRevision': revision,
  'auditHead': revision == 1 ? 'a' * 64 : 'b' * 64,
  'elements': [
    {
      'schemaVersion': 1,
      'id': cardId,
      'kind': 'card',
      'text': text,
      'x': 20.0,
      'y': 30.0,
      'color': 'yellow',
    },
  ],
  'permissions': [
    {
      'schemaVersion': 1,
      'elementId': cardId,
      'ownerId': account,
      'canEdit': true,
    },
  ],
};

FamilyBoardSnapshot snap({int revision = 1, String text = 'Film gecesi'}) =>
    FamilyBoardSnapshot.fromJson(
      snapshotJson(revision: revision, text: text),
      binding(),
    );

final class FakeBoardGateway implements FamilyBoardGateway {
  FamilyBoardSnapshot current = snap();
  Object? failure;
  int mutationAcknowledgementsToDrop = 0;
  String? deltaHeadOverride;
  Completer<FamilyBoardSnapshot>? delayedRead;
  int reads = 0, deltas = 0, mutations = 0;
  final commands = <FamilyBoardCommand>[];
  final receipts = <String, FamilyBoardReceipt>{};

  @override
  Future<FamilyBoardSnapshot> read(FamilyBoardBinding authority) async {
    reads++;
    if (failure != null) throw failure!;
    return delayedRead?.future ?? current;
  }

  @override
  Future<FamilyBoardDelta> delta(
    FamilyBoardBinding authority, {
    required int afterSequence,
  }) async {
    deltas++;
    final events = List.generate(current.boardRevision - afterSequence, (i) {
      final sequence = afterSequence + i + 1;
      return {
        'schemaVersion': 1,
        'sequence': sequence,
        'action': 'update',
        'actorId': account,
        'elementId': cardId,
        'boardRevision': sequence,
        'createdAt': 17.0 + sequence,
        'previousHash': sequence == 1
            ? '0' * 64
            : sequence == 2
            ? 'a' * 64
            : 'b' * 64,
        'eventHash': sequence == 1 ? 'a' * 64 : 'b' * 64,
      };
    });
    return FamilyBoardDelta.fromJson(
      {
        'schemaVersion': 1,
        'coreId': core,
        'homeId': home,
        'boardId': boardId,
        'boardRevision': current.boardRevision,
        'afterSequence': afterSequence,
        'nextAfter': current.boardRevision,
        'auditHead': deltaHeadOverride ?? current.auditHead,
        'events': events,
      },
      binding(),
      expectedAfter: afterSequence,
    );
  }

  @override
  Future<FamilyBoardReceipt> mutate(
    FamilyBoardBinding authority,
    FamilyBoardCommand command,
  ) async {
    mutations++;
    commands.add(command);
    if (failure != null) throw failure!;
    final replay = receipts[command.requestId];
    if (replay != null) {
      if (mutationAcknowledgementsToDrop > 0) {
        mutationAcknowledgementsToDrop--;
        throw const FamilyBoardException('request_timeout');
      }
      return replay;
    }
    current = snap(
      revision: current.boardRevision + 1,
      text: command.element is BoardCard
          ? (command.element! as BoardCard).text
          : 'Film gecesi',
    );
    final receipt = FamilyBoardReceipt.fromJson({
      'schemaVersion': 1,
      'requestId': command.requestId,
      'boardId': boardId,
      'boardRevision': current.boardRevision,
      'auditSequence': current.boardRevision,
      'action': command.action.name,
      'elementId': command.element?.id ?? command.elementId,
    }, command);
    receipts[command.requestId] = receipt;
    if (mutationAcknowledgementsToDrop > 0) {
      mutationAcknowledgementsToDrop--;
      throw const FamilyBoardException('request_timeout');
    }
    return receipt;
  }
}

final class MemoryBoardCache implements FamilyBoardCache {
  FamilyBoardSnapshot? value;
  FamilyBoardCommand? pending;
  @override
  Future<FamilyBoardSnapshot?> read(
    FamilyBoardBinding authority, {
    required bool Function() isCurrent,
  }) async => isCurrent() ? value : null;
  @override
  Future<void> write(
    FamilyBoardSnapshot snapshot, {
    required bool Function() isCurrent,
  }) async {
    if (isCurrent()) value = snapshot;
  }

  @override
  Future<FamilyBoardCommand?> readPending(
    FamilyBoardBinding authority, {
    required bool Function() isCurrent,
  }) async => isCurrent() ? pending : null;

  @override
  Future<void> writePending(
    FamilyBoardBinding authority,
    FamilyBoardCommand command, {
    required bool Function() isCurrent,
  }) async {
    if (isCurrent()) pending = command;
  }

  @override
  Future<void> clearPending(
    FamilyBoardBinding authority,
    String requestId, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent() || pending?.requestId != requestId) {
      throw const FamilyBoardException('invalid_cache');
    }
    pending = null;
  }
}

void main() {
  test('revision-zero board loads and accepts its first append', () async {
    final raw = snapshotJson()
      ..['boardRevision'] = 0
      ..['auditHead'] = '0' * 64
      ..['elements'] = <Object?>[]
      ..['permissions'] = <Object?>[];
    final gateway = FakeBoardGateway()
      ..current = FamilyBoardSnapshot.fromJson(raw, binding());
    final controller = FamilyBoardController(
      gateway: gateway,
      cache: MemoryBoardCache(),
      binding: binding(),
      isCurrent: (_) => true,
      idFactory: (() {
        var n = 8;
        return () => (n++).toRadixString(16).padLeft(32, '0');
      })(),
    );
    await controller.load();
    expect(controller.snapshot?.boardRevision, 0);
    expect(controller.canMutate, isTrue);
    await controller.createCard('İlk kart');
    expect(gateway.commands.single.expectedBoardRevision, 0);
    expect(controller.snapshot?.boardRevision, 1);

    final impossible = Map<String, Object?>.of(raw)..['auditHead'] = 'a' * 64;
    expect(
      () => FamilyBoardSnapshot.fromJson(impossible, binding()),
      throwsA(isA<FamilyBoardException>()),
    );
  });

  test('unchanged delta cannot replace the local audit head', () async {
    final gateway = FakeBoardGateway();
    final controller = FamilyBoardController(
      gateway: gateway,
      cache: MemoryBoardCache(),
      binding: binding(),
      isCurrent: (_) => true,
    );
    await controller.load();
    gateway.deltaHeadOverride = 'b' * 64;
    await controller.refreshDelta();
    expect(controller.snapshot, isNull);
    expect(controller.failure, BoardFailure.stale);
    expect(controller.canMutate, isFalse);
  });

  test(
    'strict bounded model rejects foreign authority and oversized drawing',
    () {
      expect(
        () => FamilyBoardSnapshot.fromJson(
          snapshotJson(),
          binding(memberRevision: 2),
        ),
        throwsA(isA<FamilyBoardException>()),
      );
      final raw = snapshotJson();
      raw['elements'] = [
        {
          'schemaVersion': 1,
          'id': '7' * 32,
          'kind': 'stroke',
          'color': 'blue',
          'width': 4.0,
          'points': List.generate(257, (i) => {'x': i.toDouble(), 'y': 1.0}),
        },
      ];
      expect(
        () => FamilyBoardSnapshot.fromJson(raw, binding()),
        throwsA(isA<FamilyBoardException>()),
      );
    },
  );

  test('create update delete use one exact optimistic command each', () async {
    final gateway = FakeBoardGateway();
    final cache = MemoryBoardCache();
    final controller = FamilyBoardController(
      gateway: gateway,
      cache: cache,
      binding: binding(),
      isCurrent: (value) => value == binding(),
      idFactory: (() {
        var n = 8;
        return () => (n++).toRadixString(16).padLeft(32, '0');
      })(),
    );
    await controller.load();
    await controller.createCard('Market listesi');
    await controller.updateCard(cardId, 'Yeni başlık');
    await controller.deleteElement(cardId);
    await controller.appendStroke(const [BoardPoint(1, 2), BoardPoint(3, 4)]);
    expect(gateway.mutations, 4);
    expect(gateway.commands.map((value) => value.expectedBoardRevision), [
      1,
      2,
      3,
      4,
    ]);
    expect(gateway.commands.map((value) => value.action), [
      BoardAction.append,
      BoardAction.update,
      BoardAction.delete,
      BoardAction.append,
    ]);
    expect(
      gateway.commands.map((value) => value.requestId).toSet(),
      hasLength(4),
    );
  });

  test('optimistic conflict reloads once and never replays mutation', () async {
    final gateway = FakeBoardGateway();
    final controller = FamilyBoardController(
      gateway: gateway,
      cache: MemoryBoardCache(),
      binding: binding(),
      isCurrent: (_) => true,
      idFactory: () => '8' * 32,
    );
    await controller.load();
    gateway.failure = const FamilyBoardException('revision_conflict');
    await controller.createCard('Çakışma');
    expect(gateway.mutations, 1);
    gateway.failure = null;
    gateway.current = snap(revision: 2, text: 'Başka cihaz');
    await controller.reloadAfterConflict();
    expect(gateway.mutations, 1);
    expect(controller.snapshot!.boardRevision, 2);
  });

  test(
    'lost acknowledgement retries only the exact idempotent command',
    () async {
      final gateway = FakeBoardGateway()..mutationAcknowledgementsToDrop = 1;
      final controller = FamilyBoardController(
        gateway: gateway,
        cache: MemoryBoardCache(),
        binding: binding(),
        isCurrent: (_) => true,
        idFactory: (() {
          var n = 8;
          return () => (n++).toRadixString(16).padLeft(32, '0');
        })(),
      );
      await controller.load();

      await controller.createCard('Tek etkili kart');

      expect(gateway.mutations, 2);
      expect(gateway.commands, hasLength(2));
      expect(gateway.commands[1], same(gateway.commands[0]));
      expect(gateway.commands[1].requestId, gateway.commands[0].requestId);
      expect(controller.snapshot?.boardRevision, 2);
      expect(controller.failure, isNull);
    },
  );

  test(
    'two uncertain acknowledgements retain and reconcile one command',
    () async {
      final gateway = FakeBoardGateway()..mutationAcknowledgementsToDrop = 2;
      final cache = MemoryBoardCache();
      final controller = FamilyBoardController(
        gateway: gateway,
        cache: cache,
        binding: binding(),
        isCurrent: (_) => true,
        idFactory: (() {
          var n = 8;
          return () => (n++).toRadixString(16).padLeft(32, '0');
        })(),
      );
      await controller.load();

      await controller.createCard('Belirsiz kart');

      expect(gateway.mutations, 2);
      expect(controller.pendingCommand, same(cache.pending));
      expect(controller.canMutate, isFalse);
      await controller.createCard('İkinci etki engelli');
      expect(gateway.mutations, 2);

      await controller.refreshDelta();
      expect(gateway.mutations, 3);
      expect(
        gateway.commands.map((value) => value.requestId).toSet(),
        hasLength(1),
      );
      expect(cache.pending, isNull);
      expect(controller.pendingCommand, isNull);
      expect(controller.snapshot?.boardRevision, 2);
      expect(controller.canMutate, isTrue);
    },
  );

  test(
    'offline cache is read only and delta refresh reconciles one snapshot',
    () async {
      final gateway = FakeBoardGateway();
      final cache = MemoryBoardCache()..value = snap();
      gateway.failure = const FamilyBoardException('connection_failed');
      final controller = FamilyBoardController(
        gateway: gateway,
        cache: cache,
        binding: binding(),
        isCurrent: (_) => true,
        idFactory: () => '8' * 32,
      );
      await controller.load();
      expect(controller.offline, isTrue);
      expect(controller.canMutate, isFalse);
      await controller.createCard('Engelli');
      expect(gateway.mutations, 0);

      gateway.failure = null;
      gateway.current = snap(revision: 2, text: 'Uzaktan güncel');
      await controller.refreshDelta();
      expect((gateway.deltas, gateway.reads), (2, 2));
      expect(controller.snapshot!.cards.single.text, 'Uzaktan güncel');
      expect(controller.offline, isFalse);
    },
  );

  test(
    'late route lifecycle result is discarded without cache or replay',
    () async {
      var current = true;
      final gateway = FakeBoardGateway()
        ..delayedRead = Completer<FamilyBoardSnapshot>();
      final cache = MemoryBoardCache();
      final controller = FamilyBoardController(
        gateway: gateway,
        cache: cache,
        binding: binding(),
        isCurrent: (_) => current,
        idFactory: () => '8' * 32,
      );
      final operation = controller.load();
      current = false;
      gateway.delayedRead!.complete(snap());
      await operation;
      expect(controller.snapshot, isNull);
      expect(cache.value, isNull);
      expect(controller.failure, BoardFailure.stale);
    },
  );
}
