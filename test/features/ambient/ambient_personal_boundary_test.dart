import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/ambient/data/ambient_repository.dart';
import 'package:larenor/features/ambient/domain/ambient_settings.dart';
import 'package:larenor/features/ambient/providers/ambient_providers.dart';
import 'package:larenor/features/ambient/presentation/ambient_screen.dart';
import 'package:larenor/features/wellbeing/providers/wellbeing_privacy_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../../core/direct_home_boundary_test.dart' as home;

class _Library extends AmbientRepository {
  int lists = 0, reads = 0;
  @override
  Future<List<String>> list() async {
    lists++;
    return ['a' * 64];
  }

  @override
  Future<Uint8List> readPhoto(String id) async {
    reads++;
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
  }
}

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences()
    : super.withData({
        'flutter.${AmbientSettings.preferenceKey}': const AmbientSettings()
            .encode(),
      });
  bool failWrite = false, throwWrite = false, failRead = false;
  int writes = 0;
  void Function()? afterEffect;
  Future<void> Function()? beforeEffect;
  @override
  Future<Map<String, Object>> getAll() async {
    if (failRead) throw StateError('synthetic private preferences');
    return super.getAll();
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes++;
    await beforeEffect?.call();
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
  testWidgets(
    'actual ambient screen hides cached enabled photos after a settings read failure',
    (tester) async {
      await prefs.setValue(
        'String',
        'flutter.${AmbientSettings.preferenceKey}',
        const AmbientSettings(photosEnabled: true).encode(),
      );
      final library = _Library();
      final (c, _) = await home.containerFor(
        HomeSource.directLocal,
        overrides: [
          ambientRepositoryProvider.overrideWithValue(library),
          publicHaEntitiesProvider.overrideWithValue(const AsyncData({})),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const AmbientScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      final reads = library.reads;
      final lists = library.lists;
      prefs.failRead = true;
      c.invalidate(ambientSettingsProvider);
      await tester.pumpAndSettle();
      expect(c.read(ambientSettingsProvider).hasError, isTrue);
      // Riverpod retains previous values for transitions. The actual consumer
      // must reject them whenever the current state is loading or an error.
      expect(find.byType(Image), findsNothing);
      expect(library.reads, reads);
      expect(library.lists, lists);
      await tester.pumpWidget(const SizedBox());
    },
  );
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
        expect(c.read(ambientSettingsProvider).unwrapPrevious().value, isNull);
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
    expect(c.read(ambientSettingsProvider).unwrapPrevious().value, isNull);
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
    expect(c.read(ambientSettingsProvider).unwrapPrevious().value, isNull);
  });
  test('ambient provider reread waits for a dispatched write before reading persisted opt-in', () async {
    final (c, _) = await home.containerFor(HomeSource.directLocal);
    await c.read(ambientSettingsProvider.future);
    final entered = Completer<void>(), released = Completer<void>();
    prefs.beforeEffect = () async {
      entered.complete();
      await released.future;
    };
    var current = true;
    final first = c
        .read(ambientSettingsProvider.notifier)
        .set(
          const AmbientSettings(photosEnabled: true),
          isCurrent: () => current,
        );
    final assertion = expectLater(first, throwsA(isA<AmbientException>()));
    await entered.future;
    c.invalidate(ambientSettingsProvider);
    var confirmed = false;
    final reread = c.read(ambientSettingsProvider.future).then((value) {
      confirmed = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    try {
      expect(confirmed, isFalse);
    } finally {
      current = false;
      released.complete();
      await assertion;
      await reread;
    }
    expect(
      (await reread).photosEnabled,
      isTrue,
    ); // Explicit fresh read of the actual effect.
    expect(prefs.writes, 1);
  });
  test('queued expired photo action keeps the confirmed preference and performs no write', () async {
    final (c, _) = await home.containerFor(HomeSource.directLocal);
    final old = await c.read(ambientSettingsProvider.future);
    final started = Completer<void>(), released = Completer<void>();
    final blocker = ConfigurationWrites.run(() async {
      started.complete();
      await released.future;
    });
    await started.future;
    var current = true;
    final action = c
        .read(ambientSettingsProvider.notifier)
        .set(
          const AmbientSettings(photosEnabled: true),
          isCurrent: () => current,
        );
    current = false;
    released.complete();
    await blocker;
    await action;
    expect(
      identical(c.read(ambientSettingsProvider).requireValue, old),
      isTrue,
    );
    expect(prefs.writes, 0);
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
