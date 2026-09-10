import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/keenetic/core/domain/core_keenetic_models.dart';
import 'package:larenor/features/keenetic/core/presentation/core_keenetic_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'core_keenetic_api_test.dart' show telemetryJson;

void main() {
  testWidgets('tablet and DeX panel supports 2x text, TalkBack and keyboard', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1180, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      CupertinoApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CupertinoPageScaffold(
          child: SafeArea(
            child: SingleChildScrollView(
              child: CoreKeeneticTelemetryPanel(
                telemetry: CoreKeeneticTelemetry.fromJson(telemetryJson()),
                enabled: true,
                isCurrent: () => true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('198.51.100.20'), findsOneWidget);
    expect(find.text('90 B/s'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'Public IP address.*198\.51\.100\.20')),
      findsOneWidget,
    );
    final interface = find.byKey(
      const ValueKey('core-keenetic-interface-GigabitEthernet0'),
    );
    expect(interface, findsOneWidget);
    expect(tester.getSize(interface).height, greaterThanOrEqualTo(48));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('core-keenetic-interface-rx')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('retired panel disables interface selection', (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CoreKeeneticTelemetryPanel(
          telemetry: CoreKeeneticTelemetry.fromJson(telemetryJson()),
          enabled: true,
          isCurrent: () => false,
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('core-keenetic-interface-GigabitEthernet0')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('core-keenetic-interface-rx')),
      findsNothing,
    );
  });
}
