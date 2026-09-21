import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk/data/kiosk_usage_repository.dart';
import 'package:larenor/features/kiosk/domain/kiosk_watchdog.dart';

final class _Store implements KioskUsageStore {
  String? value;
  int writes = 0;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    writes++;
    this.value = value;
  }
}

void main() {
  test('explicit recovery is bounded and never schedules an automatic retry', () async {
    var now = DateTime.utc(2026, 9, 21, 10);
    final store = _Store();
    final repository = KioskUsageRepository(store: store, now: () => now);
    final gate = KioskRecoveryGate(repository: repository, now: () => now);

    for (var i = 0; i < 3; i++) {
      expect(await gate.allowExplicitRecovery(), isTrue);
    }
    expect(await gate.allowExplicitRecovery(), isFalse);
    expect(gate.maintenanceRequired, isTrue);
    expect(gate.pendingAutomaticRecovery, isFalse);

    now = now.add(const Duration(minutes: 11));
    expect(await gate.allowExplicitRecovery(), isTrue);
    expect(gate.maintenanceRequired, isFalse);
  });

  test('local usage is content-free, bounded to 30 days and restart durable', () async {
    final store = _Store();
    var now = DateTime.utc(2026, 8, 1);
    final first = KioskUsageRepository(store: store, now: () => now);
    await first.record(KioskUsageEvent.rendererFailure);
    now = DateTime.utc(2026, 9, 21);
    final restarted = KioskUsageRepository(store: store, now: () => now);
    await restarted.record(KioskUsageEvent.timeout);
    await restarted.record(KioskUsageEvent.recoveryAttempt);
    final snapshot = await restarted.read();

    expect(snapshot.days, hasLength(1));
    expect(snapshot.days.single.timeout, 1);
    expect(snapshot.days.single.recoveryAttempt, 1);
    expect(store.value, isNot(contains('http')));
    expect(store.value, isNot(contains('token')));
    expect(store.value, isNot(contains('content')));

    final decoded = jsonDecode(store.value!) as Map<String, dynamic>;
    expect(decoded.keys, unorderedEquals(['version', 'days']));
  });

  test('CSV preview has a closed schema and corrupt storage fails closed', () async {
    final store = _Store();
    final repository = KioskUsageRepository(
      store: store,
      now: () => DateTime.utc(2026, 9, 21),
    );
    await repository.record(KioskUsageEvent.recoveryBlocked);
    final csv = await repository.csvPreview();
    expect(
      csv.split('\n').first,
      'day,renderer_failure,timeout,recovery_attempt,recovery_blocked,ready',
    );
    expect(csv, contains('2026-09-21,0,0,0,1,0'));

    store.value = '{"version":1,"days":[{"day":"2026-09-21","url":"secret"}]}';
    await expectLater(repository.read(), throwsA(isA<KioskUsageException>()));
  });
}
