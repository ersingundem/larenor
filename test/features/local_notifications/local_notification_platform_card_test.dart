import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/local_notifications/data/local_notification_platform.dart';
import 'package:larenor/features/local_notifications/presentation/local_notification_platform_card.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets(
        'explicit permission and power diagnostics remain usable at ${locale.languageCode} $width 2x',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 700);
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          var requests = 0, power = 0;
          await tester.pumpWidget(
            CupertinoApp(
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: CupertinoPageScaffold(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: LocalNotificationPlatformCard(
                      status: const AndroidNotificationStatus(
                        permission: AndroidNotificationPermission.notRequested,
                        channelEnabled: true,
                        recoveryRequired: false,
                        batteryOptimizationExempt: false,
                        deliveryMode: 'foregroundPull',
                      ),
                      onRequestPermission: () => requests++,
                      onOpenNotificationSettings: null,
                      onOpenPowerSettings: () => power++,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final enable = find.byKey(
            const ValueKey('notification-permission-request'),
          );
          final powerButton = find.byKey(
            const ValueKey('notification-power-open'),
          );
          expect(tester.getSize(enable).height, greaterThanOrEqualTo(48));
          expect(tester.getSize(powerButton).height, greaterThanOrEqualTo(48));
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          expect(requests, 1);
          await tester.tap(powerButton);
          expect(power, 1);
          expect(
            tester
                .getSemantics(find.byType(LocalNotificationPlatformCard))
                .label,
            isNotEmpty,
          );
        },
      );
    }
  }
}
