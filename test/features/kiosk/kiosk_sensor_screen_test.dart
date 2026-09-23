import 'dart:async';
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk/data/kiosk_sensor_api.dart';
import 'package:larenor/features/kiosk/domain/kiosk_sensor_models.dart';
import 'package:larenor/features/kiosk/presentation/kiosk_sensor_screen.dart';
import 'package:larenor/features/kiosk/providers/kiosk_sensor_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _session = '123e4567-e89b-12d3-a456-426614174000';

KioskSensorSnapshot _snapshot({int sequence = 0}) => KioskSensorSnapshot(
  sessionId: _session,
  sequence: sequence,
  sampling: true,
  lightAvailable: true,
  motionAvailable: false,
  observedAtElapsedMillis: 1000 + sequence,
  lux: sequence == 0 ? null : 8,
  motionDelta: null,
  cameraStatus: KioskSensorCameraStatus.busy,
);

final class _Api implements KioskSensorApi {
  int starts = 0, stops = 0, reads = 0;
  Completer<KioskSensorSnapshot>? pending;
  Completer<KioskSensorStopReceipt>? pendingStop;
  @override
  Future<KioskSensorSnapshot> start({required int intervalMillis}) async {
    starts++;
    return _snapshot();
  }

  @override
  Future<KioskSensorSnapshot> read(String sessionId) {
    reads++;
    return pending?.future ?? Future.value(_snapshot(sequence: reads));
  }

  @override
  Future<KioskSensorStopReceipt> stop(String sessionId) async {
    stops++;
    return pendingStop?.future ??
        const KioskSensorStopReceipt(sessionId: _session, stopped: true);
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required Locale locale,
  required double width,
  required _Api api,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [kioskSensorApiProvider.overrideWithValue(api)],
      child: CupertinoApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const KioskSensorScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets('${locale.languageCode} $width 2x is accessible', (
        tester,
      ) async {
        final api = _Api();
        await _pump(tester, locale: locale, width: width, api: api);
        final start = find.byKey(const ValueKey('kiosk-sensor-start'));
        expect(start, findsOneWidget);
        expect(tester.getSize(start).height, greaterThanOrEqualTo(48));
        expect(
          tester
              .getSemantics(start)
              .getSemanticsData()
              .flagsCollection
              .isButton,
          isTrue,
        );
        Focus.of(
          tester.element(
            find.descendant(of: start, matching: find.byType(Text)),
          ),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(api.starts, 1);
        expect(find.byKey(const ValueKey('kiosk-sensor-stop')), findsOneWidget);
        expect(
          find.textContaining(
            locale.languageCode == 'tr' ? 'kullanılamıyor' : 'unavailable',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining(locale.languageCode == 'tr' ? 'meşgul' : 'busy'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('background retires the sensor session and drops late reads', (
    tester,
  ) async {
    final api = _Api();
    await _pump(tester, locale: const Locale('en'), width: 600, api: api);
    await tester.tap(find.byKey(const ValueKey('kiosk-sensor-start')));
    await tester.pump();
    api.pending = Completer<KioskSensorSnapshot>();
    await tester.pump(const Duration(seconds: 2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    api.pending!.complete(_snapshot(sequence: 99));
    await tester.pump();
    expect(api.stops, 1);
    expect(find.textContaining('8'), findsNothing);
  });

  testWidgets('covering the route retires private sensor sampling', (
    tester,
  ) async {
    final api = _Api();
    await _pump(tester, locale: const Locale('en'), width: 600, api: api);
    await tester.tap(find.byKey(const ValueKey('kiosk-sensor-start')));
    await tester.pumpAndSettle();
    expect(api.starts, 1);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(CupertinoPageRoute<void>(builder: (_) => const SizedBox()));
    await tester.pumpAndSettle();
    expect(api.stops, 1);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('kiosk-sensor-start')), findsOneWidget);
  });

  testWidgets('native view focus loss retires sampling and clears readings', (
    tester,
  ) async {
    final api = _Api();
    await _pump(tester, locale: const Locale('en'), width: 600, api: api);
    await tester.tap(find.byKey(const ValueKey('kiosk-sensor-start')));
    await tester.pump(const Duration(seconds: 2));
    expect(api.reads, 1);
    expect(find.textContaining('8.0 lx'), findsOneWidget);
    api.pendingStop = Completer<KioskSensorStopReceipt>();

    tester.binding.handleViewFocusChanged(
      ViewFocusEvent(
        viewId: tester.view.viewId,
        state: ViewFocusState.unfocused,
        direction: ViewFocusDirection.undefined,
      ),
    );
    await tester.pump();

    expect(api.stops, 1);
    expect(find.textContaining('8.0 lx'), findsNothing);
    expect(
      tester
          .widget<CupertinoButton>(
            find.descendant(
              of: find.byKey(const ValueKey('kiosk-sensor-start')),
              matching: find.byType(CupertinoButton),
            ),
          )
          .onPressed,
      isNull,
    );
    api.pendingStop!.complete(
      const KioskSensorStopReceipt(sessionId: _session, stopped: true),
    );
    await tester.pump();
  });
}
