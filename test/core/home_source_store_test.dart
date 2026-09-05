import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

Matcher failure(String code) => isA<HomeSourceException>()
    .having((error) => error.code, 'code', code)
    .having((error) => error.toString(), 'safe message', 'HomeSourceException($code)');

class _Preferences implements SharedPreferences {
  final values = <String, Object>{};
  final writes = <(String, String)>[];
  Object? readError;
  Object? writeError;
  bool accept = true;

  @override
  Future<void> reload() async {}

  @override
  Object? get(String key) {
    if (readError case final error?) throw error;
    return values[key];
  }

  @override
  Future<bool> setString(String key, String value) async {
    writes.add((key, value));
    if (writeError case final error?) throw error;
    if (accept) values[key] = value;
    return accept;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RejectingPlatform extends InMemorySharedPreferencesStore {
  _RejectingPlatform() : super.withData({
    'flutter.home_source_v1': 'directLocal',
    'flutter.unrelated': 'preserved',
  });

  bool throwingWrite = false;
  bool rejectWrite = true;
  bool failRead = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (throwingWrite) throw StateError('private platform write details');
    if (rejectWrite) return false;
    return super.setValue(valueType, key, value);
  }

  @override
  Future<Map<String, Object>> getAll() async {
    if (failRead) throw StateError('private platform read details');
    return super.getAll();
  }

  @override
  Future<bool> remove(String key) => throw StateError('source must not remove');

  @override
  Future<bool> clear() => throw StateError('source must not clear');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('legacy absence selects direct local without writing or clearing', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('unrelated', 'preserved');
    expect(await SharedPreferencesHomeSourceStore().read(), HomeSource.directLocal);
    expect(prefs.getKeys(), {'unrelated'});
    expect(prefs.getString('unrelated'), 'preserved');
  });

  for (final source in HomeSource.values) {
    test('exact persisted ${source.name} survives a fresh store', () async {
      await SharedPreferencesHomeSourceStore().write(source);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {SharedPreferencesHomeSourceStore.key});
      expect(prefs.get(SharedPreferencesHomeSourceStore.key), source.name);
      expect(await SharedPreferencesHomeSourceStore().read(), source);
    });
  }

  for (final raw in <Object>[
    true, 1, 1.5, <String>[], '', 'directlocal', 'verifiedCore ',
    'DIRECT_LOCAL', 'unknown', '{"source":"verifiedCore"}',
  ]) {
    test('malformed source $raw fails closed without overwriting it', () async {
      SharedPreferences.setMockInitialValues({SharedPreferencesHomeSourceStore.key: raw});
      await expectLater(SharedPreferencesHomeSourceStore().read(), throwsA(failure('source_read_failed')));
      expect((await SharedPreferences.getInstance()).get(SharedPreferencesHomeSourceStore.key), raw);
    });
  }

  test('preference acquisition and get errors have static read failures', () async {
    final inaccessible = SharedPreferencesHomeSourceStore(
      loadPreferences: () async => throw StateError('private read details'),
    );
    await expectLater(inaccessible.read(), throwsA(failure('source_read_failed')));
    final prefs = _Preferences()..readError = StateError('private key value');
    final store = SharedPreferencesHomeSourceStore(loadPreferences: () async => prefs);
    await expectLater(store.read(), throwsA(failure('source_read_failed')));
    expect(prefs.writes, isEmpty);
  });

  test('a rejected setString is a failure and never clears stored selection', () async {
    final prefs = _Preferences()..accept = false;
    prefs.values[SharedPreferencesHomeSourceStore.key] = HomeSource.directLocal.name;
    final store = SharedPreferencesHomeSourceStore(loadPreferences: () async => prefs);
    await expectLater(store.write(HomeSource.verifiedCore), throwsA(failure('source_write_failed')));
    expect(prefs.values, {SharedPreferencesHomeSourceStore.key: HomeSource.directLocal.name});
    expect(prefs.writes, [(SharedPreferencesHomeSourceStore.key, HomeSource.verifiedCore.name)]);
  });

  test('write and acquisition exceptions are static and do not poison future writes', () async {
    final inaccessible = SharedPreferencesHomeSourceStore(
      loadPreferences: () async => throw StateError('private storage details'),
    );
    await expectLater(inaccessible.write(HomeSource.verifiedCore), throwsA(failure('source_write_failed')));
    final prefs = _Preferences()..writeError = StateError('private write details');
    final store = SharedPreferencesHomeSourceStore(loadPreferences: () async => prefs);
    await expectLater(store.write(HomeSource.verifiedCore), throwsA(failure('source_write_failed')));
    prefs.writeError = null;
    await store.write(HomeSource.verifiedCore);
    expect(await store.read(), HomeSource.verifiedCore);
  });

  for (final throwing in [false, true]) {
    test('real preferences failed write ($throwing) cannot make its cache authoritative', () async {
      SharedPreferences.resetStatic();
      final platform = _RejectingPlatform()..throwingWrite = throwing;
      SharedPreferencesStorePlatform.instance = platform;
      final prefs = await SharedPreferences.getInstance();
      final store = SharedPreferencesHomeSourceStore();
      await expectLater(store.write(HomeSource.verifiedCore), throwsA(failure('source_write_failed')));
      // The real plugin optimistically changes this cache before persisting.
      expect(prefs.get(SharedPreferencesHomeSourceStore.key), 'verifiedCore');
      expect(await store.read(), HomeSource.directLocal);
      expect((await platform.getAll())['flutter.home_source_v1'], 'directLocal');
      expect(prefs.getString('unrelated'), 'preserved');
      platform.throwingWrite = false;
      platform.rejectWrite = false;
      await store.write(HomeSource.verifiedCore);
      expect(await store.read(), HomeSource.verifiedCore);
    });
  }

  test('a reload failure rejects the old cached source instead of trusting it', () async {
    SharedPreferences.resetStatic();
    final platform = _RejectingPlatform();
    SharedPreferencesStorePlatform.instance = platform;
    await SharedPreferences.getInstance();
    platform.failRead = true;
    await expectLater(SharedPreferencesHomeSourceStore().read(), throwsA(failure('source_read_failed')));
  });

  test('source write waits for the existing whole configuration transaction', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    final transaction = ConfigurationWrites.run(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    var loads = 0;
    final prefs = _Preferences();
    final store = SharedPreferencesHomeSourceStore(loadPreferences: () async {
      loads++;
      return prefs;
    });
    final saving = store.write(HomeSource.verifiedCore);
    await Future<void>.delayed(Duration.zero);
    expect(loads, 0);
    expect(prefs.writes, isEmpty);
    release.complete();
    await transaction;
    await saving;
    expect(loads, 1);
    expect(prefs.writes, [(SharedPreferencesHomeSourceStore.key, HomeSource.verifiedCore.name)]);
  });

  test('concurrent stores preserve enqueue order through preference loading', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    final prefs = _Preferences();
    final first = SharedPreferencesHomeSourceStore(loadPreferences: () async {
      entered.complete();
      await release.future;
      return prefs;
    });
    final second = SharedPreferencesHomeSourceStore(loadPreferences: () async => prefs);
    final firstSave = first.write(HomeSource.verifiedCore);
    // Do not wait for the loader to start: queue ordering must begin at write().
    final secondSave = second.write(HomeSource.directLocal);
    await Future<void>.delayed(Duration.zero);
    expect(entered.isCompleted, isTrue);
    expect(prefs.writes, isEmpty);
    release.complete();
    await Future.wait([firstSave, secondSave]);
    expect(prefs.writes, [
      (SharedPreferencesHomeSourceStore.key, HomeSource.verifiedCore.name),
      (SharedPreferencesHomeSourceStore.key, HomeSource.directLocal.name),
    ]);
    expect(await second.read(), HomeSource.directLocal);
  });

  test('actual backup capture and replacement restore preserve local source choice', () async {
    final store = SharedPreferencesHomeSourceStore();
    final prefs = await SharedPreferences.getInstance();
    await store.write(HomeSource.verifiedCore);
    await prefs.setString('appearance', 'dark');
    final repository = BackupRepository();
    final snapshot = await repository.capture(const BackupSelection());
    final wire = jsonEncode(snapshot.toJson());
    expect(wire, isNot(contains(SharedPreferencesHomeSourceStore.key)));
    expect(wire, isNot(contains(HomeSource.verifiedCore.name)));
    final roundtrip = BackupSnapshot.fromJson(jsonDecode(wire));
    await store.write(HomeSource.directLocal);
    await prefs.setString('appearance', 'light');
    await repository.restore(roundtrip, const BackupSelection(), conflictPolicy: BackupConflictPolicy.replaceSelected);
    expect(prefs.getString('appearance'), 'dark');
    expect(await store.read(), HomeSource.directLocal);
    await store.write(HomeSource.verifiedCore);
    await repository.restore(roundtrip, const BackupSelection(), conflictPolicy: BackupConflictPolicy.replaceSelected);
    expect(await store.read(), HomeSource.verifiedCore);
    expect(backupPreferenceKeys, isNot(contains(SharedPreferencesHomeSourceStore.key)));
  });
}
