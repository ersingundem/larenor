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
                      backgroundFailure: null,
                      backgroundOutcomeUnknown: false,
                      onEnableBackground: null,
                      onMaintainBackground: null,
                      onDisableBackground: null,
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

  testWidgets('plain HTTP keeps the inbox but disables background delivery', (
    tester,
  ) async {
    var enables = 0;
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CupertinoPageScaffold(
          child: LocalNotificationPlatformCard(
            status: const AndroidNotificationStatus(
              permission: AndroidNotificationPermission.granted,
              channelEnabled: true,
              recoveryRequired: false,
              batteryOptimizationExempt: false,
              deliveryMode: 'foregroundPull',
            ),
            onRequestPermission: null,
            onOpenNotificationSettings: null,
            onOpenPowerSettings: null,
            backgroundFailure: null,
            backgroundOutcomeUnknown: false,
            backgroundEndpointUsesTls: false,
            onEnableBackground: () => enables++,
            onMaintainBackground: null,
            onDisableBackground: null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Background delivery requires a trusted HTTPS Core address. '
        'The in-app inbox remains available over this connection.',
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('notification-background-enable')),
      warnIfMissed: false,
    );
    expect(enables, 0);
  });

  for (final (locale, text) in const [
    (
      Locale('en'),
      'Delayed background delivery is scheduled through a scoped Core lease. '
          'Android decides the run time; immediate delivery is not guaranteed.',
    ),
    (
      Locale('tr'),
      'Gecikmeli arka plan teslimi kapsamı sınırlı bir Core kirasıyla '
          'zamanlandı. Çalışma zamanını Android belirler; anında teslim garanti '
          'edilmez.',
    ),
  ]) {
    testWidgets(
      'active background status states delayed Android scheduling in ${locale.languageCode}',
      (tester) async {
        await tester.pumpWidget(
          CupertinoApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: CupertinoPageScaffold(
              child: LocalNotificationPlatformCard(
                status: AndroidNotificationStatus(
                  permission: AndroidNotificationPermission.granted,
                  channelEnabled: true,
                  recoveryRequired: false,
                  batteryOptimizationExempt: false,
                  deliveryMode: 'backgroundLease',
                  backgroundDelivery: AndroidBackgroundDelivery(
                    state: AndroidBackgroundDeliveryState.active,
                    leaseId: 'a' * 32,
                    leaseRevision: 3,
                    subscriptionRevision: 4,
                    credentialFingerprint: 'b' * 64,
                    expiresAt: DateTime.utc(2026, 10, 1),
                  ),
                ),
                onRequestPermission: null,
                onOpenNotificationSettings: null,
                onOpenPowerSettings: null,
                backgroundFailure: null,
                backgroundOutcomeUnknown: false,
                onEnableBackground: null,
                onMaintainBackground: null,
                onDisableBackground: null,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining(text), findsOneWidget);
      },
    );
  }
}
