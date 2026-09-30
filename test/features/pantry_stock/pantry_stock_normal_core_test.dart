import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/pantry_stock/data/pantry_stock_api.dart';
import 'package:larenor/features/pantry_stock/data/pantry_stock_controller.dart';
import 'package:larenor/features/pantry_stock/domain/pantry_stock_models.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;
  @override
  Future<void> write(ServerSession? session) async {}
}

void main() {
  final url = Platform.environment['LARENOR_PANTRY_CORE_URL'];
  final phase = Platform.environment['LARENOR_PANTRY_PHASE'];
  const amount = PantryAmount(quantityMillis: 600000, unit: PantryUnit.gram);
  const later = PantryLotDraft(
    id:
        'a'
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    ingredientKey: 'flour',
    amount: PantryAmount(quantityMillis: 1000000, unit: PantryUnit.gram),
    expiresOn: '2026-10-31',
  );
  const earlier = PantryLotDraft(
    id:
        'b'
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    ingredientKey: 'flour',
    amount: PantryAmount(quantityMillis: 500000, unit: PantryUnit.gram),
    expiresOn: '2026-10-01',
  );
  setUpAll(() => HttpOverrides.global = null);
  test(
    'real Client pantry FEFO, replay, undo and Core restart preserve stock',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Pantry acceptance',
      );
      expect(account.failure, isNull);
      var current = true;
      final api = PantryStockAccountApi(
        account: account,
        context: account.session!.context!,
        isCurrent: () => current,
      );
      final ids = ['1' * 32, '2' * 32, '3' * 32, '4' * 32].iterator;
      final controller = PantryStockController(
        api,
        requestIds: () {
          expect(ids.moveNext(), isTrue);
          return ids.current;
        },
      );
      addTearDown(controller.dispose);
      expect(await controller.load(), isTrue);
      final file = File(Platform.environment['LARENOR_PANTRY_STATE_FILE']!);
      if (phase == 'mutate') {
        expect(controller.snapshot!.revision, 0);
        expect(await controller.receive(later), isTrue);
        expect(await controller.receive(earlier), isTrue);
        expect(
          await controller.consume('flour', amount),
          isTrue,
          reason: controller.failure,
        );
        expect(controller.snapshot!.revision, 3);
        expect(controller.snapshot!.lots.single.lotId, later.id);
        expect(controller.snapshot!.lots.single.remaining, 900000);
        final consumeReplay = await api.consume(
          requestId: '3' * 32,
          expectedRevision: 2,
          ingredientKey: 'flour',
          amount: amount,
        );
        expect(consumeReplay.snapshot.revision, 3);
        final movement = controller.undoMovementId!;
        expect(await controller.undo(), isTrue, reason: controller.failure);
        expect(controller.snapshot!.revision, 4);
        expect(controller.undoMovementId, isNull);
        expect(
          controller.snapshot!.lots.fold<int>(0, (n, lot) => n + lot.remaining),
          1500000,
        );
        await file.writeAsString(jsonEncode({'movementId': movement}));
        // An old exact replay must return its original receipt together with the
        // current snapshot, without rolling the Client back or consuming again.
        final oldReceive = await api.receive(
          requestId: '1' * 32,
          expectedRevision: 0,
          lot: later,
        );
        expect(oldReceive.receipt.revision, 1);
        expect(oldReceive.snapshot.revision, 4);
        await expectLater(
          api.consume(
            requestId: '5' * 32,
            expectedRevision: 2,
            ingredientKey: 'flour',
            amount: amount,
          ),
          throwsA(isA<LarenorServerException>()),
        );
        expect((await api.snapshot()).revision, 4);
      } else {
        expect(controller.snapshot!.revision, 4);
        expect(controller.snapshot!.lots.length, 2);
        final saved =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final replay = await api.undo(
          requestId: '4' * 32,
          expectedRevision: 3,
          movementId: saved['movementId'] as String,
        );
        expect(replay.snapshot.revision, 4);
        expect(
          replay.snapshot.lots.fold<int>(0, (n, lot) => n + lot.remaining),
          1500000,
        );
      }
      current = false;
      await expectLater(
        api.snapshot(),
        throwsA(
          isA<LarenorServerException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
    },
    skip: url == null
        ? 'Run with server/tests/support/f32_flutter_acceptance.py'
        : false,
  );
}
