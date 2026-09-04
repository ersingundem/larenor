import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/health/data/action_controller.dart';
import 'package:larenor/features/health/data/action_receipt.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/health/providers/action_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/action_status_indicator.dart';

void main() {
  Future<void> mount(WidgetTester tester, ActionController controller) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [actionControllerProvider.overrideWithValue(controller)],
        child: CupertinoApp(
          locale: const Locale('tr'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const CupertinoPageScaffold(
              child: SafeArea(
                child: SingleChildScrollView(
                  child: ActionStatusIndicator(entityId: 'light.example'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ActionKey key(String target) => ActionKey(
    integration: IntegrationId.ha,
    target: target,
    action: 'light.turn_on',
  );

  testWidgets('distinguishes sending, acceptance and observed state', (
    tester,
  ) async {
    final controller = ActionController(now: () => DateTime(2026, 9, 5, 12));
    addTearDown(controller.dispose);
    final ack = Completer<void>();
    final events = StreamController<String>.broadcast(sync: true);
    addTearDown(events.close);
    await mount(tester, controller);
    expect(
      find.byKey(const ValueKey('action-status-light.example')),
      findsNothing,
    );
    final result = controller.execute<String>(
      key: key('light.example'),
      send: () => ack.future,
      observations: events.stream,
      confirms: (value) => value == 'on',
    );
    await tester.pumpAndSettle();
    expect(find.text('İstek gönderiliyor'), findsOneWidget);
    ack.complete();
    await tester.pumpAndSettle();
    expect(find.text('İstek kabul edildi · durum bekleniyor'), findsOneWidget);
    expect(find.text('Home Assistant istenen durumu bildirdi'), findsNothing);
    events.add('on');
    await tester.pumpAndSettle();
    expect((await result).status, ActionStatus.confirmed);
    expect(find.text('Home Assistant istenen durumu bildirdi'), findsOneWidget);
    expect(find.textContaining('Son istek ·'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('without observable result, success only means acceptance', (
    tester,
  ) async {
    final controller = ActionController();
    addTearDown(controller.dispose);
    await controller.execute<void>(
      key: key('light.example'),
      send: () async {},
    );
    await mount(tester, controller);
    expect(find.text('Home Assistant isteği kabul etti'), findsOneWidget);
    expect(find.text('Home Assistant istenen durumu bildirdi'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('lost acknowledgement stays uncertain and isolated per target', (
    tester,
  ) async {
    final controller = ActionController();
    addTearDown(controller.dispose);
    await controller.execute<void>(key: key('light.other'), send: () async {});
    await mount(tester, controller);
    expect(find.text('Home Assistant isteği kabul etti'), findsNothing);
    await controller.execute<void>(
      key: key('light.example'),
      send: () async => throw TimeoutException('private transport details'),
      classifyFailure: (_) => ActionFailure.timeout,
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Sonuç doğrulanamadı. Tekrar denemeden önce cihazı kontrol et.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('private transport'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
