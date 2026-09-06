import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/core/home_data_scope.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/home_scope/data/core_layout_archive_controller.dart';
import 'package:larenor/features/home_scope/domain/core_layout_archive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _FaultStore extends InMemorySharedPreferencesStore {
  _FaultStore(Map<String, Object> data, this.target, this.mode)
    : super.withData(data);
  final String target, mode;
  int writes = 0;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key != target) return super.setValue(valueType, key, value);
    writes++;
    if (mode.startsWith('after')) {
      await super.setValue(valueType, key, value);
    }
    if (mode.endsWith('throw')) throw StateError('synthetic write failure');
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final scope = HomeDataScope.fromJson({
    'coreId': 'a' * 32,
    'homeId': 'b' * 32,
    'userId': 'owner',
  });
  const currentLayout = DashboardLayout(
    rooms: [DashboardRoom(id: 'current', name: 'Current room')],
  );
  const savedLayout = DashboardLayout(
    rooms: [
      DashboardRoom(id: 'saved-2', name: 'Çalışma odası'),
      DashboardRoom(id: 'saved-1', name: 'Salon'),
    ],
  );
  late DashboardRepository repository;
  late bool current;
  late DateTime now;
  CoreLayoutArchiveController controller() => CoreLayoutArchiveController(
    destination: repository,
    isCurrent: () => current,
    clock: () => now,
  );
  CoreLayoutArchiveV1 archive({HomeDataScope? owner, DashboardLayout? layout}) =>
      CoreLayoutArchiveV1.fromScopedLayout(
        scope: owner ?? scope,
        sourceRevision: 100,
        capturedAt: DateTime.utc(2026, 1, 1),
        layout: (layout ?? savedLayout).toJson(),
      );
  Future<Map<String, Object>> disk() async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    return {for (final k in p.getKeys()) k: p.get(k)!};
  }
  Matcher failure(String code) => throwsA(
    isA<DashboardStorageException>().having((e) => e.code, 'code', code),
  );
  setUp(() {
    current = true;
    now = DateTime.utc(2026, 9, 6, 12, 34, 56, 123, 456);
    SharedPreferences.setMockInitialValues({
      'dashboard_layout': 'legacy must not be read or modified',
      'synthetic_token': 'must remain unchanged',
      'dashboard_layout_core_v1_unrelated': 'unrelated home',
    });
    repository = DashboardRepository.core(scope: scope, isCurrent: () => true);
  });

  test('capture reads only current scoped rooms and canonicalizes UTC milliseconds', () async {
    await repository.save(savedLayout);
    final before = await disk();
    final captured = await controller().capture();
    expect(captured.matchesScope(scope), isTrue);
    expect(captured.sourceRevision, 1);
    expect(captured.capturedAt.toIso8601String(), '2026-09-06T12:34:56.123Z');
    expect(captured.rooms.map((r) => r.id), ['saved-2', 'saved-1']);
    expect(captured.rooms.map((r) => r.name), ['Çalışma odası', 'Salon']);
    expect(captured.encode(), isNot(contains('synthetic_token')));
    expect(await disk(), before);
  });
  test('missing scoped layout captures empty revision zero without legacy fallback', () async {
    final captured = await controller().capture();
    expect(captured.rooms, isEmpty);
    expect(captured.sourceRevision, 0);
    expect((await disk()).containsKey(scope.storageKey), isFalse);
  });
  test('preview and confirmed restore retain IDs and order, increment target revision once', () async {
    await repository.save(currentLayout);
    final c = controller();
    final before = await disk();
    final preview = await c.preview(archive());
    expect(preview.currentRoomNames, ['Current room']);
    expect(preview.archivedRoomNames, ['Çalışma odası', 'Salon']);
    expect(await disk(), before);
    expect(() => preview.currentRoomNames.add('bad'), throwsUnsupportedError);
    expect(() => preview.archivedRoomNames.clear(), throwsUnsupportedError);
    await c.apply(preview);
    final snapshot = await repository.readSnapshot();
    expect(snapshot.revision, 2); // Captured source revision100 is not installed.
    expect(snapshot.layout, savedLayout);
    final after = await disk();
    after.remove(scope.storageKey);
    before.remove(scope.storageKey);
    expect(after, before);
    await expectLater(c.apply(preview), failure('expired'));
    expect((await repository.readSnapshot()).revision, 2);
    expect(preview.toString(), 'CoreLayoutArchivePreview');
    expect(c.toString(), 'CoreLayoutArchiveController');
  });
  test('explicit empty archive clears only current passive rooms', () async {
    await repository.save(currentLayout);
    final c = controller();
    await c.apply(await c.preview(archive(layout: const DashboardLayout())));
    expect((await repository.load()).rooms, isEmpty);
    expect((await disk())['dashboard_layout'], isNotNull);
  });
  for (final field in ['coreId', 'homeId', 'userId']) {
    test('foreign $field archive is rejected before destination read', () async {
      final p = await SharedPreferences.getInstance();
      await p.setString(scope.storageKey, 'corrupt target');
      final owner = HomeDataScope.fromJson({
        ...scope.toJson(), field: field == 'userId' ? 'other' : 'c' * 32,
      });
      final before = await disk();
      await expectLater(controller().preview(archive(owner: owner)), failure('scope_mismatch'));
      expect(await disk(), before);
    });
  }
  test('Direct destination cannot construct a Core archive controller', () {
    expect(
      () => CoreLayoutArchiveController(destination: DashboardRepository(), isCurrent: () => true),
      failure('expired'),
    );
  });
  for (final operation in ['capture', 'preview']) {
    test('$operation rejects unsupported current device bindings without stripping', () async {
      await repository.save(currentLayout.copyWith(favoriteEntityIds: ['light.private']));
      final before = await disk();
      final c = controller();
      await expectLater(operation == 'capture' ? c.capture() : c.preview(archive()),
        throwsA(isA<CoreLayoutArchiveException>().having((e) => e.code, 'code', 'unsupported_layout')));
      expect(await disk(), before);
    });
    test('$operation preserves malformed scoped record', () async {
      await (await SharedPreferences.getInstance()).setString(scope.storageKey, '{broken');
      final before = await disk();
      final c = controller();
      await expectLater(operation == 'capture' ? c.capture() : c.preview(archive()), failure('invalid_record'));
      expect(await disk(), before);
    });
  }
  for (final reason in ['target-revision', 'same-revision-content', 'expiry', 'backwards', 'authority', 'closed', 'owner']) {
    test('restore rejects changed $reason and preserves current disk', () async {
      await repository.save(currentLayout);
      final c = controller();
      final preview = await c.preview(archive());
      if (reason == 'target-revision') await repository.save(savedLayout);
      if (reason == 'same-revision-content') {
        final prefs = await SharedPreferences.getInstance();
        final raw = jsonDecode(prefs.getString(scope.storageKey)!) as Map<String, dynamic>;
        raw['layout'] = savedLayout.toJson();
        await prefs.setString(scope.storageKey, jsonEncode(raw));
      }
      if (reason == 'expiry') now = now.add(CoreLayoutArchiveController.lifetime);
      if (reason == 'backwards') now = now.subtract(const Duration(seconds: 1));
      if (reason == 'authority') current = false;
      if (reason == 'closed') c.close();
      final before = await disk();
      await expectLater((reason == 'owner' ? controller() : c).apply(preview),
        failure(reason.contains('revision') ? 'changed' : 'expired'));
      expect(await disk(), before);
    });
  }
  test('observed lost authority permanently retires capture and preview', () async {
    final c = controller();
    current = false;
    await expectLater(c.capture(), failure('expired'));
    current = true;
    await expectLater(c.capture(), failure('expired'));
    await expectLater(c.preview(archive()), failure('expired'));
  });
  test('queued restore rechecks authority and consumes preview without retry', () async {
    final c = controller();
    final p = await c.preview(archive());
    final entered = Completer<void>(), release = Completer<void>();
    final blocking = ConfigurationWrites.run(() async { entered.complete(); await release.future; });
    await entered.future;
    final applying = c.apply(p);
    final rejected = expectLater(applying, failure('expired'));
    current = false;
    release.complete();
    await blocking;
    await rejected;
    current = true;
    await expectLater(c.apply(p), failure('expired'));
    expect((await disk()).containsKey(scope.storageKey), isFalse);
  });
  for (final mode in ['before-false', 'before-throw', 'after-false', 'after-throw']) {
    test('$mode write remains unresolved and never rolls back or retries', () async {
      await repository.save(currentLayout);
      final c = controller();
      final preview = await c.preview(archive());
      final data = await disk();
      final platform = _FaultStore({for (final e in data.entries) 'flutter.${e.key}': e.value}, 'flutter.${scope.storageKey}', mode);
      SharedPreferencesStorePlatform.instance = platform;
      await expectLater(c.apply(preview), failure('write_failed'));
      await expectLater(c.apply(preview), failure('expired'));
      expect(platform.writes, 1);
      final stored = await repository.load();
      expect(stored, mode.startsWith('after') ? savedLayout : currentLayout);
      expect((await disk())['synthetic_token'], data['synthetic_token']);
    });
  }
}
