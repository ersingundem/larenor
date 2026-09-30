import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/cooking_assistant/data/cooking_session_api.dart';
import 'package:larenor/features/cooking_assistant/data/cooking_timers_controller.dart';
import 'package:larenor/features/cooking_assistant/data/cooking_timers_storage.dart';
import 'package:larenor/features/cooking_assistant/data/ingredient_deduction_api.dart';
import 'package:larenor/features/cooking_assistant/data/ingredient_deduction_controller.dart';
import 'package:larenor/features/cooking_assistant/domain/cooking_timer.dart';
import 'package:larenor/features/cooking_assistant/domain/ingredient_deduction.dart';
import 'package:larenor/features/pantry_stock/data/pantry_stock_api.dart';
import 'package:larenor/features/pantry_stock/domain/pantry_stock_models.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? value) async {}
}

final class _Clock implements CookingTimerClock {
  _Clock({required this.wall, required this.monotonic});

  Duration wall;
  Duration monotonic;

  @override
  Duration get wallNow => wall;

  @override
  Duration get monotonicNow => monotonic;
}

final class _Notifications implements CookingTimerNotifications {
  final Set<String> delivered = {};

  @override
  Future<void> finished({
    required String idempotencyKey,
    required String label,
  }) async {
    delivered.add(idempotencyKey);
  }
}

IngredientDeductionPreview _preview({
  required String accountId,
  required String sessionId,
  required int sessionRevision,
  required int pantryRevision,
}) => IngredientDeductionPreview.fromDraft(
  IngredientDeductionDraft(
    accountId: accountId,
    recipeSessionId: sessionId,
    recipeRevision: 7,
    completedStep: 1,
    stepRevision: sessionRevision,
    expectedPantryRevision: pantryRevision,
    items: const [
      IngredientDeductionItem(stockItemId: 'flour', quantityMicros: 250),
    ],
  ),
);

void main() {
  final coreUrl = Platform.environment['LARENOR_COOKING_CORE_URL'];
  final phase = Platform.environment['LARENOR_COOKING_PHASE'];
  final stateFile = Platform.environment['LARENOR_COOKING_STATE_FILE'];

  setUpAll(() => HttpOverrides.global = null);

  test(
    'real Client persists cooking, pantry deduction and timers across restart',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: coreUrl!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Cooking acceptance',
      );
      expect(account.failure, isNull);
      final session = account.session!;
      final context = session.context!;
      final pantry = PantryStockAccountApi(
        account: account,
        context: context,
        isCurrent: () => true,
      );
      final cooking = CookingSessionAccountApi(
        account: account,
        isCurrent: () => true,
      );
      addTearDown(pantry.close);
      addTearDown(cooking.close);

      if (phase == 'prepare') {
        final empty = await pantry.snapshot();
        expect(empty.revision, 0);
        final received = await pantry.receive(
          requestId: '1' * 32,
          expectedRevision: empty.revision,
          lot: const PantryLotDraft(
            id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            ingredientKey: 'flour',
            amount: PantryAmount(quantityMillis: 1000, unit: PantryUnit.gram),
            expiresOn: '2026-10-31',
          ),
        );
        expect(received.snapshot.revision, 1);
        final created = await cooking.create(
          recipeId: 'recipe.normal-core-gate',
          recipeRevision: 7,
          title: 'Acceptance bread',
          steps: const ['Prepare dough', 'Bake'],
        );
        final moved = await cooking.move(
          sessionId: created.id,
          expectedRevision: created.revision,
          step: 1,
        );
        final preview = _preview(
          accountId: session.user.id,
          sessionId: moved.id,
          sessionRevision: moved.revision,
          pantryRevision: received.snapshot.revision,
        );
        final deductionApi = IngredientDeductionAccountApi(
          account: account,
          context: context,
          preview: preview,
          isCurrent: () => true,
        );
        addTearDown(deductionApi.close);
        final deduction = IngredientDeductionController(
          gateway: deductionApi,
          preview: preview,
          isCurrent: () => true,
        );
        addTearDown(deduction.dispose);
        final confirmed = await deduction.confirm();
        expect(confirmed, isTrue, reason: '${deduction.failure}');
        expect(deduction.receipt!.pantryRevision, 2);
        final replay = await deductionApi.commit(preview);
        expect(replay.idempotencyKey, preview.idempotencyKey);
        final after = await pantry.snapshot();
        expect(after.revision, 2);
        expect(after.lots.single.remaining, 750);

        SharedPreferences.setMockInitialValues({});
        final timerStore = SharedPreferencesCookingTimerStore();
        final authority = CookingTimerAuthority(
          accountId: session.user.id,
          recipeSessionId: moved.id,
          epoch: 1,
        );
        final firstTimers = CookingTimersController(
          store: timerStore,
          notifications: _Notifications(),
          clock: _Clock(
            wall: const Duration(hours: 100),
            monotonic: const Duration(hours: 5),
          ),
          authority: authority,
          isCurrent: () => true,
        );
        await firstTimers.restore();
        expect(
          await firstTimers.start(
            label: 'Oven',
            duration: const Duration(minutes: 10),
          ),
          isTrue,
        );
        firstTimers.dispose();
        final restoredTimers = CookingTimersController(
          store: timerStore,
          notifications: _Notifications(),
          clock: _Clock(
            wall: const Duration(hours: 100, minutes: 4),
            monotonic: const Duration(seconds: 2),
          ),
          authority: CookingTimerAuthority(
            accountId: session.user.id,
            recipeSessionId: moved.id,
            epoch: 2,
          ),
          isCurrent: () => true,
        );
        addTearDown(restoredTimers.dispose);
        await restoredTimers.restore();
        expect(restoredTimers.timers.single.label, 'Oven');
        expect(
          restoredTimers.remaining(restoredTimers.timers.single),
          const Duration(minutes: 6),
        );

        await File(stateFile!).writeAsString(
          jsonEncode({
            'accountId': session.user.id,
            'sessionId': moved.id,
            'sessionRevision': moved.revision,
            'deductionKey': preview.idempotencyKey,
          }),
          flush: true,
        );
      } else {
        final saved = jsonDecode(await File(stateFile!).readAsString());
        expect(saved, isA<Map<String, dynamic>>());
        final state = saved as Map<String, dynamic>;
        expect(session.user.id, state['accountId']);
        final snapshot = await pantry.snapshot();
        expect(snapshot.revision, 2);
        expect(snapshot.lots.single.remaining, 750);
        final restored = await cooking.get(state['sessionId'] as String);
        expect(restored.revision, state['sessionRevision']);
        expect(restored.currentStep, 1);
        final preview = _preview(
          accountId: session.user.id,
          sessionId: restored.id,
          sessionRevision: restored.revision,
          pantryRevision: 1,
        );
        expect(preview.idempotencyKey, state['deductionKey']);
        final deductionApi = IngredientDeductionAccountApi(
          account: account,
          context: context,
          preview: preview,
          isCurrent: () => true,
        );
        addTearDown(deductionApi.close);
        final receipt = await deductionApi.receipt(preview.idempotencyKey);
        expect(receipt!.pantryRevision, 2);
        final replay = await deductionApi.commit(preview);
        expect(replay.idempotencyKey, receipt.idempotencyKey);
        expect((await pantry.snapshot()).revision, 2);
      }
    },
    skip: coreUrl == null || phase == null || stateFile == null
        ? 'Requires explicit isolated normal Core runner'
        : false,
  );
}
