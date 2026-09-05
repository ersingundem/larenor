import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/idle_prevention.dart';
import 'package:larenor/features/ambient/data/ambient_repository.dart';
import 'package:larenor/features/ambient/domain/ambient_settings.dart';
import 'package:larenor/features/ambient/presentation/ambient_screen.dart';
import 'package:larenor/features/ambient/presentation/ambient_settings_screen.dart';
import 'package:larenor/features/ambient/providers/ambient_providers.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/settings/presentation/idle_gate.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/features/wellbeing/providers/wellbeing_privacy_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
final _a = 'a' * 64, _b = 'b' * 64;

class _Repository extends AmbientRepository {
  List<String> ids = [];
  final reads = <String>[];
  final values = <String, Future<Uint8List>>{};
  int imports = 0, changes = 0;
  @override
  Future<List<String>> list() async => List.of(ids);
  @override
  Future<Uint8List> readPhoto(String id) {
    reads.add(id);
    return values[id] ?? Future.value(_png);
  }

  @override
  Future<void> importPhoto(
    Uint8List source, {
    required bool Function() isCurrent,
  }) async {
    if (isCurrent()) {
      imports++;
      ids.add(_a);
    }
  }

  @override
  Future<void> replaceOrder(
    List<String> next, {
    required List<String> expected,
    required bool Function() isCurrent,
  }) async {
    if (isCurrent()) {
      changes++;
      ids = List.of(next);
    }
  }
}

class _Files extends AmbientFileAccess {
  int picks = 0;
  Future<Uint8List?>? pending;
  @override
  Future<Uint8List?> pickPhoto() {
    picks++;
    return pending ?? Future.value(_png);
  }
}

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => null;
}

class _Idle extends IdleMode {
  @override
  Future<IdleModeSettings> build() async =>
      const IdleModeSettings(enabled: true, timeoutMinutes: 1);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump();
  }
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  Widget child, {
  _Repository? repository,
  _Files? files,
  AppInteractionController? interaction,
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      ambientRepositoryProvider.overrideWithValue(repository ?? _Repository()),
      ambientFileAccessProvider.overrideWithValue(files ?? _Files()),
      connectionConfigProvider.overrideWith(_Connection.new),
      publicHaEntitiesProvider.overrideWithValue(const AsyncData({})),
      idleModeProvider.overrideWith(_Idle.new),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: CupertinoApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, body) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: interaction == null
              ? body!
              : AppInteractionScope(controller: interaction, child: body!),
        ),
        home: child,
      ),
    ),
  );
  await _frames(tester);
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final size in [
    const Size(320, 640),
    const Size(1000, 360),
    const Size(1366, 900),
  ]) {
    testWidgets('ambient settings remain reachable at $size and 200% text', (
      tester,
    ) async {
      final repo = _Repository()..ids = [_a, _b];
      await _mount(
        tester,
        const AmbientSettingsScreen(),
        repository: repo,
        size: size,
        scale: 2,
      );
      await tester.scrollUntilVisible(
        find.text('Choose a photo'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Photo 2'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('ambient switches announce each setting name', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await _mount(
        tester,
        const AmbientSettingsScreen(),
        size: const Size(600, 1100),
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(AmbientSettingsScreen)),
      );
      final labels = [
        l10n.ambientPhotosEnabled,
        l10n.ambientClock,
        l10n.ambientWeather,
        l10n.ambientShift,
      ];
      for (var i = 0; i < labels.length; i++) {
        final control = find.byType(CupertinoSwitch).at(i);
        await tester.ensureVisible(control);
        await _frames(tester);
        expect(tester.getSemantics(control).label, contains(labels[i]));
      }
      await tester.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
    }
  });
  testWidgets('explicit file selection imports once and refreshes collection', (
    tester,
  ) async {
    final repo = _Repository();
    final files = _Files();
    await _mount(
      tester,
      const AmbientSettingsScreen(),
      repository: repo,
      files: files,
    );
    await tester.scrollUntilVisible(
      find.text('Choose a photo'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Choose a photo'));
    await tester.pump();
    await _frames(tester);
    expect(files.picks, 1);
    expect(repo.imports, 1);
    expect(find.text('Photo 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'late file result after idle is discarded without a gate runner',
    (tester) async {
      final repo = _Repository();
      final selected = Completer<Uint8List?>();
      final files = _Files()..pending = selected.future;
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      await _mount(
        tester,
        const AmbientSettingsScreen(),
        repository: repo,
        files: files,
        interaction: interaction,
      );
      await tester.scrollUntilVisible(
        find.text('Choose a photo'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Choose a photo'));
      await tester.pump();
      interaction.setActive(false);
      interaction.setActive(true);
      selected.complete(_png);
      await _frames(tester);
      expect(repo.imports, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('captured photo button cannot run after idle and wake', (
    tester,
  ) async {
    final files = _Files();
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    await _mount(
      tester,
      const AmbientSettingsScreen(),
      files: files,
      interaction: interaction,
    );
    await tester.scrollUntilVisible(
      find.text('Choose a photo'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final button = tester
        .widget<CupertinoButton>(
          find
              .ancestor(
                of: find.text('Choose a photo'),
                matching: find.byType(CupertinoButton),
              )
              .first,
        )
        .onPressed!;
    interaction.setActive(false);
    interaction.setActive(true);
    await _frames(tester);
    button();
    await _frames(tester);
    expect(files.picks, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('removal needs confirmation and keeps unrelated selections', (
    tester,
  ) async {
    final repo = _Repository()..ids = [_a, _b];
    await _mount(tester, const AmbientSettingsScreen(), repository: repo);
    await tester.scrollUntilVisible(
      find.byKey(ValueKey('ambient-remove-$_a')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(
      tester.element(find.byKey(ValueKey('ambient-remove-$_a'))),
      alignment: 0.5,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await _frames(tester);
    await tester.tap(find.byKey(ValueKey('ambient-remove-$_a')));
    await tester.pump(const Duration(milliseconds: 500));
    await _frames(tester);
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
    await tester.pump(const Duration(milliseconds: 500));
    await _frames(tester);
    expect(repo.changes, 0);
    await Scrollable.ensureVisible(
      tester.element(find.byKey(ValueKey('ambient-remove-$_a'))),
      alignment: 0.5,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await _frames(tester);
    await tester.tap(find.byKey(ValueKey('ambient-remove-$_a')));
    await tester.pump(const Duration(milliseconds: 500));
    await _frames(tester);
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Remove'));
    await tester.pump(const Duration(milliseconds: 500));
    await _frames(tester);
    expect(repo.ids, [_b]);
    expect(repo.changes, 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'unreadable photo album falls back to clock without endless retry',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        AmbientSettings.preferenceKey: const AmbientSettings(
          photosEnabled: true,
          showClock: false,
          showWeather: false,
        ).encode(),
      });
      final repository = _Repository()..ids = [_a];
      final failure = Future<Uint8List>.error(const AmbientException());
      failure.ignore();
      repository.values[_a] = failure;
      await _mount(tester, const AmbientScreen(), repository: repository);
      expect(
        find.byKey(const ValueKey('ambient-photo-fallback')),
        findsOneWidget,
      );
      expect(repository.reads, [_a]);
      await tester.pump(const Duration(minutes: 5));
      expect(repository.reads, [_a]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('sequence skips broken copies and stops after all fail', (
    tester,
  ) async {
    final repo = _Repository();
    final failure = Future<Uint8List>.error(const AmbientException());
    failure.ignore();
    repo.values[_a] = failure;
    await _mount(
      tester,
      AmbientPhotoSequence(
        repository: repo,
        ids: [_a, _b],
        interval: const Duration(seconds: 30),
        fit: AmbientPhotoFit.contain,
        active: true,
      ),
    );
    expect(repo.reads, [_a, _b]);
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('late previous-album bytes never replace the current photo', (
    tester,
  ) async {
    final repo = _Repository();
    final first = Completer<Uint8List>();
    repo.values[_a] = first.future;
    Widget sequence(List<String> ids) => CupertinoApp(
      home: AmbientPhotoSequence(
        repository: repo,
        ids: ids,
        interval: const Duration(seconds: 30),
        fit: AmbientPhotoFit.contain,
        active: true,
      ),
    );
    await tester.pumpWidget(sequence([_a]));
    await tester.pump();
    await tester.pumpWidget(sequence([_b]));
    await _frames(tester);
    first.complete(Uint8List.fromList([1, 2, 3]));
    await _frames(tester);
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as MemoryImage).bytes, same(_png));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('inactive photo sequence releases content and stops reads', (
    tester,
  ) async {
    final repo = _Repository();
    Widget sequence(bool active) => CupertinoApp(
      home: AmbientPhotoSequence(
        repository: repo,
        ids: [_a, _b],
        interval: const Duration(seconds: 30),
        fit: AmbientPhotoFit.cover,
        active: active,
      ),
    );
    await tester.pumpWidget(sequence(true));
    await _frames(tester);
    await tester.pumpWidget(sequence(false));
    await _frames(tester);
    expect(find.byType(Image), findsNothing);
    await tester.pump(const Duration(minutes: 3));
    expect(repo.reads.length, 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'active video lease prevents idle; releasing it restarts a full timeout',
    (tester) async {
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      final container = await _mount(
        tester,
        IdleGate(
          child: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, value, _) => PreventAmbientDisplay(
              active: value,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(minutes: 2));
      await _frames(tester);
      expect(container.read(idlePreventionProvider).prevented, isTrue);
      expect(find.byType(AmbientScreen), findsNothing);
      active.value = false;
      await _frames(tester);
      await tester.pump(const Duration(seconds: 59));
      expect(find.byType(AmbientScreen), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await _frames(tester);
      expect(find.byType(AmbientScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('independent video leases release safely in any disposal order', () {
    final controller = IdlePreventionController();
    final a = Object(), b = Object();
    controller.set(a, true);
    controller.set(b, true);
    controller.set(a, false);
    expect(controller.prevented, isTrue);
    controller.set(b, false);
    expect(controller.prevented, isFalse);
    controller.dispose();
    controller.set(a, false);
  });
}
