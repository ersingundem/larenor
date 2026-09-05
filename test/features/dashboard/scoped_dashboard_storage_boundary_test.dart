import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_data_scope.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

final scope = HomeDataScope.fromJson({'coreId': 'a' * 32, 'homeId': 'b' * 32, 'userId': 'one'});
const layout = DashboardLayout(rooms: [DashboardRoom(id: 'room', name: 'Private room')]);

class StoragePlatform extends InMemorySharedPreferencesStore {
  StoragePlatform() : super.withData({'flutter.unrelated': 'kept'});
  bool commitFirst = false, throwWrite = false, failRead = false;
  int writes = 0;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes++;
    if (commitFirst) await super.setValue(valueType, key, value);
    if (throwWrite) throw StateError('private details');
    return false;
  }
  @override
  Future<Map<String, Object>> getAll() async {
    if (failRead) throw StateError('private details');
    return super.getAll();
  }
}
class RetiringPreferences implements SharedPreferences {
  RetiringPreferences(this.retire);
  final void Function() retire;
  int reads = 0;
  @override
  Future<void> reload() async {
    scheduleMicrotask(() => scheduleMicrotask(retire));
  }
  @override
  Object? get(String key) {
    reads++;
    return jsonEncode({'version': 1, 'scope': scope.toJson(), 'revision': 1, 'layout': layout.toJson()});
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final load in [false, true]) {
    test('retirement after reload but before publication rejects ${load ? "load" : "snapshot"}', () async {
      var active = true;
      final prefs = RetiringPreferences(() => active = false);
      final repo = DashboardRepository.core(scope: scope, isCurrent: () => active, loadPreferences: () async => prefs);
      await expectLater(load ? repo.load() : repo.readSnapshot(), throwsA(isA<DashboardStorageException>()));
      expect(active, isFalse);
    });
  }
  for (final commitFirst in [false, true]) {
    for (final throwing in [false, true]) {
      for (final failReload in [false, true]) {
        test('false/throw write before/after commit $commitFirst/$throwing, reload failure $failReload is never success', () async {
          SharedPreferences.resetStatic();
          final platform = StoragePlatform()..commitFirst = commitFirst..throwWrite = throwing;
          SharedPreferencesStorePlatform.instance = platform;
          final prefs = await SharedPreferences.getInstance();
          final repo = DashboardRepository.core(scope: scope, isCurrent: () => true);
          await expectLater(repo.save(layout), throwsA(isA<DashboardStorageException>().having((e) => e.code, 'code', 'write_failed')));
          expect(platform.writes, 1);
          // Real plugin cache changed optimistically even when the platform rejected.
          expect(prefs.get(scope.storageKey), isNotNull);
          platform.failRead = failReload;
          final restarted = DashboardRepository.core(scope: scope, isCurrent: () => true);
          if (failReload) {
            await expectLater(restarted.load(), throwsA(isA<DashboardStorageException>().having((e) => e.code, 'code', 'read_failed')));
          } else {
            expect((await restarted.load()).rooms.length, commitFirst ? 1 : 0);
          }
          expect(platform.writes, 1);
          platform.failRead = false;
          expect((await platform.getAll())['flutter.unrelated'], 'kept');
        });
      }
    }
  }
}
