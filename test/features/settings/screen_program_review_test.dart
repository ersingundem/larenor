import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/settings/data/screen_program_store.dart';
import 'package:larenor/features/settings/domain/screen_program.dart';
import 'package:larenor/features/settings/presentation/screen_program_screen.dart';
import 'package:larenor/features/settings/providers/screen_program_provider.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backup/backup_test_storage.dart';

ScreenProgram _weekly() => ScreenProgram(
  enabled: true,
  rules: [
    ScreenProgramRule(
      id: 'all-day',
      days: {1, 2, 3, 4, 5, 6, 7},
      startMinutes: 0,
      endMinutes: 1440,
      awake: ScreenAwakeMode.keepAwake,
    ),
  ],
);

class _Store implements ScreenProgramStore {
  String? raw;
  @override
  Future<String?> read() async => raw;
  @override
  Future<void> write(String value) async {
    raw = value;
  }
}

Future<void> _mount(
  WidgetTester tester, {
  Size size = const Size(560, 240),
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final interaction = AppInteractionController();
  addTearDown(interaction.dispose);
  final store = _Store()..raw = ScreenProgram().encode();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [screenProgramStoreProvider.overrideWithValue(store)],
      child: CupertinoApp(
        locale: const Locale('tr'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => AppInteractionScope(
          controller: interaction,
          child: MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
        ),
        home: const ScreenProgramScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('weekly program does not surface an unused corrupt legacy preference future', () async {
    SharedPreferences.setMockInitialValues({
      ScreenProgram.preferenceKey: _weekly().encode(),
      'night_start_minutes': 'invalid old preference',
    });
    final errors = <Object>[];
    final finished = Completer<void>();
    runZonedGuarded(() async {
      final container = ProviderContainer();
      try {
        final program = await container.read(screenProgramProvider.future);
        expect(program.encode(), _weekly().encode());
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      } finally {
        container.dispose();
        finished.complete();
      }
    }, (error, _) => errors.add(error));
    await finished.future;
    expect(
      errors,
      isEmpty,
      reason:
          'A valid weekly program must not depend on retired legacy storage.',
    );
  });

  test(
    'replacing settings from a legacy vault restores its actual night behavior',
    () async {
      final storage = MemoryBackupStorage(
        preferences: {ScreenProgram.preferenceKey: _weekly().encode()},
      );
      final snapshot = BackupSnapshot.fromJson({
        'version': 1,
        'createdAt': '2026-09-05T00:00:00.000Z',
        'groups': {
          'settings': {
            'night_start_minutes': 1320,
            'night_end_minutes': 420,
            'dim_brightness_at_night': true,
            'screen_off_at_night': true,
          },
        },
      });
      await BackupRepository(storage: storage).restore(
        snapshot,
        const BackupSelection(
          settings: true,
          dashboard: false,
          connections: false,
        ),
        conflictPolicy: BackupConflictPolicy.replaceSelected,
      );
      SharedPreferences.setMockInitialValues({
        for (final e in storage.preferences.entries)
          if (e.value != null) e.key: e.value!,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final program = await container.read(screenProgramProvider.future);
      expect(
        program.evaluate(DateTime(2026, 9, 5, 23), defaultKeepAwake: true),
        const ScreenPolicy(keepAwake: false, dim: true),
      );
      expect(
        program.evaluate(DateTime(2026, 9, 5, 12), defaultKeepAwake: false),
        ScreenPolicy.released,
      );
    },
  );

  testWidgets(
    'time editor popup is usable in a short DeX window at 200 percent text',
    (tester) async {
      await _mount(tester);
      final add = find.byKey(const ValueKey('screen-program-add'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      final start = find.byKey(const ValueKey('screen-rule-start'));
      await tester.ensureVisible(start);
      await tester.pumpAndSettle();
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoDatePicker), findsOneWidget);
      final done = find.widgetWithText(
        CupertinoButton,
        AppLocalizations.of(tester.element(find.byType(CupertinoDatePicker)))
            .commonDone,
      );
      expect(done.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('screen program switches announce their setting names', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await _mount(tester, size: const Size(600, 1100));
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ScreenProgramScreen)),
      );
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('screen-program-enabled')))
            .label,
        contains(l10n.screenProgramEnabled),
      );
      final add = find.byKey(const ValueKey('screen-program-add'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      for (final entry in {
        'screen-rule-enabled': l10n.adminEnabled,
        'screen-rule-all-day': l10n.screenProgramAllDay,
        'screen-rule-dim': l10n.screenProgramDim,
      }.entries) {
        final control = find.byKey(ValueKey(entry.key));
        await tester.ensureVisible(control);
        await tester.pumpAndSettle();
        expect(tester.getSemantics(control).label, contains(entry.value));
      }
    } finally {
      semantics.dispose();
    }
  });
}
