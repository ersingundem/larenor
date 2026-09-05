import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/ambient/data/ambient_repository.dart';
import 'package:larenor/features/ambient/domain/ambient_settings.dart';
import 'package:larenor/features/ambient/providers/ambient_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../../core/direct_home_boundary_test.dart' as home;

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences()
    : super.withData({
        'flutter.${AmbientSettings.preferenceKey}': const AmbientSettings()
            .encode(),
      });
  bool failWrite = false, throwWrite = false, failRead = false;
  int writes = 0;
  void Function()? afterEffect;
  @override
  Future<Map<String, Object>> getAll() async {
    if (failRead) throw StateError('synthetic private preferences');
    return super.getAll();
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes++;
    if (throwWrite) throw StateError('synthetic private write');
    if (failWrite) return false;
    final result = await super.setValue(type, key, value);
    afterEffect?.call();
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Preferences prefs;
  late SharedPreferencesStorePlatform previous;
  setUp(() {
    SharedPreferences.resetStatic();
    previous = SharedPreferencesStorePlatform.instance;
    prefs = _Preferences();
    SharedPreferencesStorePlatform.instance = prefs;
  });
  tearDown(() {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });
  for (final source in HomeSource.values) {
    test(
      '${source.name} explicit device library provider reads retained photos without network or source migration',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'larenor-personal-photo-',
        );
        addTearDown(() => root.delete(recursive: true));
        final repository = AmbientRepository(
          directory: () async => root,
          normalize: (bytes) async => bytes,
        );
        final photo = Uint8List.fromList([1, 3, 5, 7]);
        await repository.importPhoto(photo, isCurrent: () => true);
        final original = await File('${root.path}/library.json').readAsBytes();
        final (c, _) = await home.containerFor(
          source,
          overrides: [ambientRepositoryProvider.overrideWithValue(repository)],
        );
        final ids = await c.read(ambientLibraryProvider.future);
        expect(ids, hasLength(1));
        expect(await c.read(ambientPhotoProvider(ids.single).future), photo);
        expect(await File('${root.path}/library.json').readAsBytes(), original);
        expect((await root.list().toList()).length, 2);
        expect(prefs.writes, 0);
      },
    );
  }
  for (final failure in ['false', 'throw']) {
    test(
      '$failure preference write never reappears as a confirmed photo opt-in from memory cache',
      () async {
        final (c, _) = await home.containerFor(HomeSource.verifiedCore);
        await c.read(ambientSettingsProvider.future);
        prefs.failWrite = failure == 'false';
        prefs.throwWrite = failure == 'throw';
        await expectLater(
          c
              .read(ambientSettingsProvider.notifier)
              .set(
                const AmbientSettings(photosEnabled: true),
                isCurrent: () => true,
              ),
          throwsA(isA<AmbientException>()),
        );
        expect(c.read(ambientSettingsProvider).hasError, isTrue);
        expect(c.read(ambientSettingsProvider).value, isNull);
        prefs.failWrite = false;
        prefs.throwWrite = false;
        c.invalidate(ambientSettingsProvider);
        expect(
          (await c.read(ambientSettingsProvider.future)).photosEnabled,
          isFalse,
        );
        expect(prefs.writes, 1);
      },
    );
  }
  test('late preference write after action expiration never publishes enabled photo state', () async {
    final (c, _) = await home.containerFor(HomeSource.directLocal);
    await c.read(ambientSettingsProvider.future);
    var current = true;
    prefs.afterEffect = () => current = false;
    await expectLater(
      c
          .read(ambientSettingsProvider.notifier)
          .set(
            const AmbientSettings(photosEnabled: true),
            isCurrent: () => current,
          ),
      throwsA(isA<AmbientException>()),
    );
    expect(c.read(ambientSettingsProvider).hasError, isTrue);
    expect(c.read(ambientSettingsProvider).value, isNull);
    expect(prefs.writes, 1); // Dispatched write is not rolled back or retried.
  });
  test('fresh provider read failure is static and cannot reuse an old opt-in cache', () async {
    final (c, _) = await home.containerFor(HomeSource.verifiedCore);
    await c.read(ambientSettingsProvider.future);
    await c
        .read(ambientSettingsProvider.notifier)
        .set(const AmbientSettings(photosEnabled: true), isCurrent: () => true);
    prefs.failRead = true;
    c.invalidate(ambientSettingsProvider);
    await expectLater(
      c.read(ambientSettingsProvider.future),
      throwsA(isA<AmbientException>()),
    );
    expect(c.read(ambientSettingsProvider).value, isNull);
  });
  test(
    'throwing action cannot mutate preferences or disclose callback details',
    () async {
      final (c, _) = await home.containerFor(HomeSource.directLocal);
      await c.read(ambientSettingsProvider.future);
      await expectLater(
        c
            .read(ambientSettingsProvider.notifier)
            .set(
              const AmbientSettings(photosEnabled: true),
              isCurrent: () => throw StateError('private callback'),
            ),
        throwsA(isA<AmbientException>()),
      );
      expect(prefs.writes, 0);
    },
  );
  test('corrupted device photo manifest is an error rather than an empty migrated library', () async {
    final root = await Directory.systemTemp.createTemp(
      'larenor-personal-photo-',
    );
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/library.json');
    await file.writeAsString('{"version":true,"photos":[]}');
    final (c, _) = await home.containerFor(
      HomeSource.verifiedCore,
      overrides: [
        ambientRepositoryProvider.overrideWithValue(
          AmbientRepository(directory: () async => root),
        ),
      ],
    );
    await expectLater(
      c.read(ambientLibraryProvider.future),
      throwsA(isA<AmbientException>()),
    );
    expect(c.read(ambientLibraryProvider).hasError, isTrue);
    expect(await file.readAsString(), '{"version":true,"photos":[]}');
  });
}
