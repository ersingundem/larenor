import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_data_scope.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:shared_preferences/shared_preferences.dart';

final scopeA = HomeDataScope.fromJson({
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
  'userId': 'one',
});
final scopeB = HomeDataScope.fromJson({
  'coreId': 'a' * 32,
  'homeId': 'c' * 32,
  'userId': 'one',
});
const local = DashboardLayout(
  rooms: [DashboardRoom(id: 'room', name: 'Local room')],
);

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'dashboard_layout': jsonEncode(local.toJson()),
    }),
  );
  test('missing Core record stays empty and scoped saves never change legacy or another home', () async {
    final a = DashboardRepository.core(scope: scopeA, isCurrent: () => true);
    final b = DashboardRepository.core(scope: scopeB, isCurrent: () => true);
    expect((await a.load()).rooms, isEmpty);
    await a.save(local);
    expect(await a.load(), local);
    expect((await b.load()).rooms, isEmpty);
    expect(await DashboardRepository().load(), local);
    final stored = jsonDecode(
      (await SharedPreferences.getInstance()).getString(scopeA.storageKey)!,
    );
    expect(stored['scope'], scopeA.toJson());
    expect(stored['revision'], 1);
    expect(stored.keys.toSet(), {'version', 'scope', 'revision', 'layout'});
    expect(
      await DashboardRepository.core(
        scope: scopeA,
        isCurrent: () => true,
      ).load(),
      local,
    );
  });
  test(
    'denied Core access performs no preference read and cannot fall back',
    () async {
      var reads = 0;
      final repo = DashboardRepository.core(
        scope: scopeA,
        isCurrent: () => false,
        loadPreferences: () async {
          reads++;
          return SharedPreferences.getInstance();
        },
      );
      await expectLater(repo.load(), throwsA(isA<DashboardStorageException>()));
      await expectLater(
        repo.save(local),
        throwsA(isA<DashboardStorageException>()),
      );
      expect(reads, 0);
    },
  );
  for (final problem in [
    'type',
    'json',
    'scope',
    'revision',
    'extra',
    'oversize',
  ]) {
    test(
      'corrupt $problem record fails closed without overwriting any record',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final record = {
          'version': 1,
          'scope': scopeA.toJson(),
          'revision': 1,
          'layout': local.toJson(),
        };
        if (problem == 'scope') record['scope'] = scopeB.toJson();
        if (problem == 'revision') record['revision'] = 1.0;
        if (problem == 'extra') record['extra'] = 'not allowed';
        if (problem == 'type') {
          await prefs.setInt(scopeA.storageKey, 4);
        } else {
          await prefs.setString(scopeA.storageKey, switch (problem) {
            'json' => '{',
            'oversize' => 'x' * (3 * 1024 * 1024),
            _ => jsonEncode(record),
          });
        }
        final before = prefs.get(scopeA.storageKey);
        final repo = DashboardRepository.core(
          scope: scopeA,
          isCurrent: () => true,
        );
        await expectLater(
          repo.load(),
          throwsA(isA<DashboardStorageException>()),
        );
        await expectLater(
          repo.save(local),
          throwsA(isA<DashboardStorageException>()),
        );
        await prefs.reload();
        expect(prefs.get(scopeA.storageKey), before);
        expect(await DashboardRepository().load(), local);
      },
    );
  }
  test(
    'an expected snapshot cannot overwrite another durable revision',
    () async {
      final repo = DashboardRepository.core(
        scope: scopeA,
        isCurrent: () => true,
      );
      final before = await repo.readSnapshot();
      await repo.save(local);
      await expectLater(
        repo.save(const DashboardLayout(), expected: before),
        throwsA(isA<DashboardStorageException>()),
      );
      expect(await repo.load(), local);
      expect((await repo.readSnapshot()).revision, 1);
    },
  );
}
