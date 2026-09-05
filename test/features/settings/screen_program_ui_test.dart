import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/settings/data/screen_program_store.dart';
import 'package:larenor/features/settings/domain/screen_program.dart';
import 'package:larenor/features/settings/presentation/screen_program_screen.dart';
import 'package:larenor/features/settings/providers/screen_program_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

class _Store implements ScreenProgramStore {
  _Store([ScreenProgram? initial])
    : raw = (initial ?? ScreenProgram()).encode();
  String raw;
  int writes = 0;
  bool fail = false;
  Completer<void>? pending;
  ScreenProgram get program => ScreenProgram.decode(raw);
  @override
  Future<String?> read() async => raw;
  @override
  Future<void> write(String value) async {
    writes++;
    await pending?.future;
    if (fail) throw StateError('private storage path');
    raw = value;
  }
}

ScreenProgramRule _rule(String id, {bool enabled = true}) => ScreenProgramRule(
  id: id,
  name: id,
  days: {1, 2, 3, 4, 5},
  startMinutes: 1320,
  endMinutes: 420,
  dim: true,
  enabled: enabled,
);
Future<void> _mount(
  WidgetTester tester,
  _Store store, {
  AppInteractionController? interaction,
  Size size = const Size(600, 1000),
  double scale = 1,
  Locale locale = const Locale('en'),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = interaction ?? AppInteractionController();
  if (interaction == null) addTearDown(controller.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [screenProgramStoreProvider.overrideWithValue(store)],
      child: CupertinoApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => AppInteractionScope(
          controller: controller,
          child: MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: const ScreenProgramScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'opening a schedule does not write settings or issue platform commands',
    (tester) async {
      final s = _Store();
      await _mount(tester, s);
      expect(s.writes, 0);
      expect(
        find.text('No time periods yet. Add one to create a weekly schedule.'),
        findsOneWidget,
      );
      expect(find.textContaining('does not lock or turn off'), findsOneWidget);
    },
  );
  testWidgets(
    'explicit editor saves weekdays, all-day and timeout separately from dimming',
    (tester) async {
      final s = _Store();
      await _mount(tester, s);
      await _tap(tester, 'screen-program-add');
      await tester.enterText(
        find.byKey(const ValueKey('screen-rule-name')),
        'Monday wall panel',
      );
      for (var day = 2; day <= 7; day++) {
        await _tap(tester, 'screen-rule-day-$day');
      }
      await _tap(tester, 'screen-rule-all-day');
      await _tap(tester, 'screen-rule-mode-systemTimeout');
      await _tap(tester, 'screen-rule-dim');
      expect(s.writes, 0);
      await _tap(tester, 'screen-rule-save');
      expect(s.writes, 1);
      final r = s.program.rules.single;
      expect(r.days, {1});
      expect(r.startMinutes, 0);
      expect(r.endMinutes, 1440);
      expect(r.awake, ScreenAwakeMode.systemTimeout);
      expect(r.dim, isFalse);
      expect(r.name, 'Monday wall panel');
      expect(s.program.enabled, isFalse);
      await _tap(tester, 'screen-program-enabled');
      expect(s.program.enabled, isTrue);
    },
  );
  testWidgets(
    'all weekdays removed prevents save and leaves durable schedule untouched',
    (tester) async {
      final s = _Store();
      await _mount(tester, s);
      await _tap(tester, 'screen-program-add');
      for (var day = 1; day <= 7; day++) {
        await _tap(tester, 'screen-rule-day-$day');
      }
      await _tap(tester, 'screen-rule-save');
      expect(s.writes, 0);
      expect(find.textContaining('Choose at least one day'), findsOneWidget);
    },
  );
  testWidgets(
    'editing a disabled imported rule preserves disabled unless explicitly changed',
    (tester) async {
      final s = _Store(
        ScreenProgram(
          enabled: true,
          rules: [_rule('inactive', enabled: false)],
        ),
      );
      await _mount(tester, s);
      await _tap(tester, 'screen-rule-inactive');
      expect(
        tester
            .widget<CupertinoSwitch>(
              find.byKey(const ValueKey('screen-rule-enabled')),
            )
            .value,
        isFalse,
      );
      await _tap(tester, 'screen-rule-save');
      expect(s.program.rules.single.enabled, isFalse);
      await _tap(tester, 'screen-rule-inactive');
      await _tap(tester, 'screen-rule-enabled');
      await _tap(tester, 'screen-rule-save');
      expect(s.program.rules.single.enabled, isTrue);
    },
  );
  testWidgets(
    'move changes persisted priority and delete requires explicit named confirmation',
    (tester) async {
      final s = _Store(
        ScreenProgram(
          enabled: true,
          rules: [_rule('weekday'), _rule('exception')],
        ),
      );
      await _mount(tester, s);
      await _tap(tester, 'screen-rule-up-exception');
      expect(s.program.rules.map((r) => r.id), ['exception', 'weekday']);
      await _tap(tester, 'screen-rule-delete-exception');
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(s.writes, 1);
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
      await tester.pumpAndSettle();
      expect(s.writes, 1);
      await _tap(tester, 'screen-rule-delete-exception');
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Delete'));
      await tester.pumpAndSettle();
      expect(s.program.rules.map((r) => r.id), ['weekday']);
      expect(s.writes, 2);
    },
  );
  testWidgets('storage failure preserves prior schedule with a safe error', (
    tester,
  ) async {
    final s = _Store()..fail = true;
    await _mount(tester, s);
    await _tap(tester, 'screen-program-enabled');
    expect(s.program.enabled, isFalse);
    expect(
      find.textContaining('Your previous schedule remains in use'),
      findsOneWidget,
    );
    expect(find.textContaining('private storage'), findsNothing);
  });
  testWidgets(
    'rapid captured switch callbacks serialize a single explicit save',
    (tester) async {
      final s = _Store()..pending = Completer<void>();
      await _mount(tester, s);
      final change = tester
          .widget<CupertinoSwitch>(
            find.byKey(const ValueKey('screen-program-enabled')),
          )
          .onChanged!;
      change(true);
      change(true);
      await tester.pump();
      expect(s.writes, 1);
      expect(s.program.enabled, isFalse);
      s.pending!.complete();
      await tester.pumpAndSettle();
      expect(s.program.enabled, isTrue);
    },
  );
  testWidgets(
    'idle closes owned editor and old Save callback cannot revive on wake',
    (tester) async {
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      final s = _Store();
      await _mount(tester, s, interaction: interaction);
      await _tap(tester, 'screen-program-add');
      final oldSave = tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('screen-rule-save')),
          )
          .onPressed!;
      interaction.setActive(false);
      await tester.pumpAndSettle();
      interaction.setActive(true);
      await tester.pumpAndSettle();
      oldSave();
      await tester.pumpAndSettle();
      expect(s.writes, 0);
      expect(find.byKey(const ValueKey('screen-rule-name')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'idle pending deletion and retained confirmation callback perform zero writes',
    (tester) async {
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      final s = _Store(ScreenProgram(rules: [_rule('sleep')]));
      await _mount(tester, s, interaction: interaction);
      await _tap(tester, 'screen-rule-delete-sleep');
      final confirm = tester
          .widget<CupertinoDialogAction>(
            find.widgetWithText(CupertinoDialogAction, 'Delete'),
          )
          .onPressed!;
      interaction.setActive(false);
      await tester.pumpAndSettle();
      interaction.setActive(true);
      await tester.pumpAndSettle();
      confirm();
      await tester.pumpAndSettle();
      expect(s.writes, 0);
      expect(s.program.rules, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'background time picker callbacks are invalidated and write nothing',
    (tester) async {
      final s = _Store();
      await _mount(tester, s);
      await _tap(tester, 'screen-program-add');
      await _tap(tester, 'screen-rule-start');
      final picker = tester.widget<CupertinoDatePicker>(
        find.byType(CupertinoDatePicker),
      );
      final done = tester
          .widget<CupertinoButton>(find.widgetWithText(CupertinoButton, 'Done'))
          .onPressed!;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      picker.onDateTimeChanged(DateTime(2026, 1, 5, 6));
      done();
      await tester.pumpAndSettle();
      expect(s.writes, 0);
      expect(find.byType(CupertinoDatePicker), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('queued save cannot write after global interaction expires', (
    tester,
  ) async {
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    final s = _Store();
    await _mount(tester, s, interaction: interaction);
    final blocker = Completer<void>();
    final lock = ConfigurationWrites.run(() => blocker.future);
    final change = tester
        .widget<CupertinoSwitch>(
          find.byKey(const ValueKey('screen-program-enabled')),
        )
        .onChanged!;
    change(true);
    await tester.pump();
    interaction.setActive(false);
    await tester.pump();
    blocker.complete();
    await lock;
    await tester.pumpAndSettle();
    interaction.setActive(true);
    await tester.pumpAndSettle();
    expect(s.writes, 0);
    expect(s.program.enabled, isFalse);
  });
  for (final size in [const Size(320, 640), const Size(1366, 1024)]) {
    testWidgets('schedule and editor remain scrollable at $size / 200% text', (
      tester,
    ) async {
      final s = _Store();
      // ID remains machine-safe; visible names exercise wrapping separately.
      s.raw = ScreenProgram(
        rules: [
          ScreenProgramRule(
            id: 'long',
            name: 'Weekdays with a sufficiently long rule name',
            days: {1, 2, 3, 4, 5, 6, 7},
            startMinutes: 1320,
            endMinutes: 420,
          ),
        ],
      ).encode();
      await _mount(tester, s, size: size, scale: 2, locale: const Locale('tr'));
      expect(tester.takeException(), isNull);
      await _tap(tester, 'screen-rule-long');
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('screen-rule-dim')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('screen-rule-dim')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _tap(tester, 'screen-rule-save');
      expect(s.writes, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
