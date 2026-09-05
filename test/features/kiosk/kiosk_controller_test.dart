import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk/data/kiosk_api.dart';
import 'package:larenor/features/kiosk/data/kiosk_controller.dart';
import 'package:larenor/features/kiosk/domain/kiosk_models.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';

class _Pin extends PinLockStore {
  String? value = '1234';
  bool accept = true;
  int checks = 0;
  Duration retry = Duration.zero;
  Completer<void>? pending;
  bool removeDuringVerification = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<PinAttemptResult> verify(String candidate) async {
    checks++;
    await pending?.future;
    if (removeDuringVerification) value = null;
    return PinAttemptResult(
      accepted: accept && candidate == '1234',
      retryAfter: retry,
    );
  }
}

class _Api extends KioskApi {
  int proposals = 0, writes = 0, cancels = 0;
  Completer<void>? pendingPrepare, pendingExecute;
  KioskOutcome outcome = KioskOutcome.observed;
  bool failExecute = false;
  @override
  Future<KioskSnapshot> snapshot() async =>
      KioskSnapshot(supported: true, actions: {KioskAction.enter});
  @override
  Future<KioskIntent> prepare(KioskAction action) async {
    proposals++;
    await pendingPrepare?.future;
    return KioskIntent(
      id: 'opaque-0000000000000000',
      action: action,
      snapshot: await snapshot(),
    );
  }

  @override
  Future<KioskReceipt> execute(KioskIntent intent) async {
    writes++;
    if (failExecute) throw StateError('private bridge failure');
    await pendingExecute?.future;
    return KioskReceipt(outcome, await snapshot());
  }

  @override
  Future<void> cancel(KioskIntent intent) async {
    cancels++;
  }
}

Matcher failure(KioskFailure f) =>
    isA<KioskException>().having((e) => e.failure, 'failure', f);
Future<void> flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'read and prepare never write Android policy or reuse gate authorization',
    () async {
      final api = _Api(), pin = _Pin();
      final c = KioskController(api, pin);
      await c.snapshot();
      await c.prepare(KioskAction.enter, isCurrent: () => true);
      expect(api.writes, 0);
      expect(pin.checks, 0);
    },
  );
  for (final value in [null, '', 'bad']) {
    test('missing or invalid PIN prevents native proposal: $value', () async {
      final api = _Api(), pin = _Pin()..value = value;
      final c = KioskController(api, pin);
      await expectLater(
        c.prepare(KioskAction.enter, isCurrent: () => true),
        throwsA(failure(KioskFailure.pinRequired)),
      );
      expect(api.proposals, 0);
      expect(api.writes, 0);
    });
  }
  test(
    'each action verifies PIN afresh; same intent cannot execute twice',
    () async {
      final api = _Api(), pin = _Pin();
      final c = KioskController(api, pin);
      final intent = await c.prepare(KioskAction.enter, isCurrent: () => true);
      await c.execute(intent, '1234', isCurrent: () => true);
      expect(pin.checks, 1);
      expect(api.writes, 1);
      await expectLater(
        c.execute(intent, '1234', isCurrent: () => true),
        throwsA(failure(KioskFailure.expired)),
      );
      final second = await c.prepare(KioskAction.exit, isCurrent: () => true);
      await c.execute(second, '1234', isCurrent: () => true);
      expect(pin.checks, 2);
      expect(api.writes, 2);
    },
  );
  test(
    'wrong PIN consumes the proposal but performs no policy write',
    () async {
      final api = _Api(), pin = _Pin();
      final c = KioskController(api, pin);
      final intent = await c.prepare(KioskAction.enter, isCurrent: () => true);
      await expectLater(
        c.execute(intent, '9999', isCurrent: () => true),
        throwsA(failure(KioskFailure.wrongPin)),
      );
      expect(pin.checks, 1);
      expect(api.writes, 0);
    },
  );
  test('rate limit preserves retry delay and no native mutation', () async {
    final api = _Api(),
        pin = _Pin()
          ..accept = false
          ..retry = const Duration(seconds: 30);
    final c = KioskController(api, pin);
    final intent = await c.prepare(KioskAction.enter, isCurrent: () => true);
    await expectLater(
      c.execute(intent, '9999', isCurrent: () => true),
      throwsA(
        isA<KioskException>().having(
          (e) => e.retryAfter,
          'retry',
          const Duration(seconds: 30),
        ),
      ),
    );
    expect(api.writes, 0);
  });
  test(
    'removing PIN during verify cannot exploit missing-PIN accepted semantics',
    () async {
      final api = _Api(), pin = _Pin()..removeDuringVerification = true;
      final c = KioskController(api, pin);
      final intent = await c.prepare(KioskAction.enter, isCurrent: () => true);
      await expectLater(
        c.execute(intent, '1234', isCurrent: () => true),
        throwsA(failure(KioskFailure.expired)),
      );
      expect(api.writes, 0);
    },
  );
  test('background and wake while PIN verification is pending cannot revive authorization', () async {
    final api = _Api(), pin = _Pin()..pending = Completer<void>();
    final c = KioskController(api, pin);
    final intent = await c.prepare(KioskAction.enter, isCurrent: () => true);
    final future = c.execute(intent, '1234', isCurrent: () => true);
    final check = expectLater(future, throwsA(failure(KioskFailure.expired)));
    await flush();
    c.invalidate();
    pin.pending!.complete();
    await check;
    expect(api.writes, 0);
  });
  test(
    'late prepare after interaction expires is cancelled instead of retained',
    () async {
      final api = _Api()..pendingPrepare = Completer<void>();
      final c = KioskController(api, _Pin());
      final future = c.prepare(KioskAction.enter, isCurrent: () => true);
      final check = expectLater(future, throwsA(failure(KioskFailure.expired)));
      await flush();
      c.invalidate();
      api.pendingPrepare!.complete();
      await check;
      expect(api.cancels, 1);
      expect(api.writes, 0);
    },
  );
  test('duplicate execution during a pending native call sends exactly one command', () async {
    final api = _Api()..pendingExecute = Completer<void>();
    final c = KioskController(api, _Pin());
    final intent = await c.prepare(KioskAction.enter, isCurrent: () => true);
    final first = c.execute(intent, '1234', isCurrent: () => true);
    await flush();
    await expectLater(
      c.execute(intent, '1234', isCurrent: () => true),
      throwsA(failure(KioskFailure.busy)),
    );
    expect(api.writes, 1);
    api.pendingExecute!.complete();
    await first;
  });
  test('unknown result is preserved and never retried', () async {
    final api = _Api()..outcome = KioskOutcome.unknown;
    final c = KioskController(api, _Pin());
    final intent = await c.prepare(KioskAction.enter, isCurrent: () => true);
    expect(
      (await c.execute(intent, '1234', isCurrent: () => true)).outcome,
      KioskOutcome.unknown,
    );
    expect(api.writes, 1);
  });
  test('unexpected bridge failure after dispatch returns unknown and sends no retry', () async {
    final api = _Api()..failExecute = true;
    final c = KioskController(api, _Pin());
    final intent = await c.prepare(KioskAction.enter, isCurrent: () => true);
    expect(
      (await c.execute(intent, '1234', isCurrent: () => true)).outcome,
      KioskOutcome.unknown,
    );
    expect(api.writes, 1);
  });
  test('dispose invalidates a confirmation without applying it', () async {
    final api = _Api();
    final c = KioskController(api, _Pin());
    final intent = await c.prepare(KioskAction.enter, isCurrent: () => true);
    c.dispose();
    await expectLater(
      c.execute(intent, '1234', isCurrent: () => true),
      throwsA(failure(KioskFailure.expired)),
    );
    expect(api.writes, 0);
  });
}
