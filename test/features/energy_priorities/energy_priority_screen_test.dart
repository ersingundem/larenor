import 'package:flutter/cupertino.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/energy_priorities/data/energy_priority_controller.dart';
import 'package:larenor/features/energy_priorities/presentation/energy_priority_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'energy_priority_controller_test.dart' as fixture;

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets(
        '${locale.languageCode} $width 2x is accessible and bounded',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1100);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          final controller = EnergyPriorityController(
            api: fixture.FakeEnergyPriorityApi(),
            backtestApi: fixture.FakeBacktestApi(
              Future.value(fixture.backtest(fixture.snapshot())),
            ),
            isCurrent: () => true,
          );
          await tester.pumpWidget(
            CupertinoApp(
              locale: locale,
              supportedLocales: const [Locale('en'), Locale('tr')],
              localizationsDelegates: const [
                AppLocalizations.delegate,
                ...GlobalCupertinoLocalizations.delegates,
              ],
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: EnergyPriorityScreen(controller: controller),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('energy-reserve-percent')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('energy-reserve-backtest')),
            findsOneWidget,
          );
          expect(
            find.text(
              locale.languageCode == 'tr'
                  ? 'Kayıtlı rezerv incelemesi'
                  : 'Recorded reserve review',
            ),
            findsOneWidget,
          );
          final action = find.byKey(const ValueKey('energy-preview-action'));
          expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
          expect(
            tester
                .getSemantics(action)
                .getSemanticsData()
                .hasAction(SemanticsAction.tap),
            isTrue,
          );
          final actionLabel = find.descendant(
            of: action,
            matching: find.text(
              locale.languageCode == 'tr'
                  ? 'İlk eylemi önizle'
                  : 'Preview first action',
            ),
          );
          Focus.of(tester.element(actionLabel)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('energy-confirm-action')),
            findsOneWidget,
          );
          controller.dispose();
        },
      );
    }
  }

  testWidgets('reserve-only inverter exposes percent confirmation, not power', (
    tester,
  ) async {
    final controller = EnergyPriorityController(
      api: fixture.FakeEnergyPriorityApi(reserveOnly: true),
      isCurrent: () => true,
    );
    await tester.pumpWidget(
      CupertinoApp(
        supportedLocales: const [Locale('en'), Locale('tr')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        home: EnergyPriorityScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('energy-preview-action')), findsNothing);
    expect(
      find.byKey(const ValueKey('energy-preview-reserve')),
      findsOneWidget,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('energy-preview-reserve')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('energy-confirm-reserve')),
      findsOneWidget,
    );
    controller.dispose();
  });

  testWidgets('admin verifies Fronius source before reserve controls appear', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final api = fixture.FakeEnergyPriorityApi();
    final controller = EnergyPriorityController(
      api: api,
      reserveSetupApi: fixture.FakeReserveSetupApi(api),
      isCurrent: () => true,
    );
    await tester.pumpWidget(
      CupertinoApp(
        supportedLocales: const [Locale('en'), Locale('tr')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        home: EnergyPriorityScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('energy-reserve-source-picker')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('energy-reserve-entity')),
      'number.gen24_battery_minimum_reserve',
    );
    await tester.pump();
    final bind = find.byKey(const ValueKey('energy-reserve-bind-source'));
    await tester.ensureVisible(bind);
    await tester.tap(bind);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('energy-preview-reserve')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('energy-reserve-source-picker')),
      findsNothing,
    );
    controller.dispose();
  });
}
