import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk_remote/data/kiosk_remote_api.dart';
import 'package:larenor/features/kiosk_remote/data/kiosk_remote_controller.dart';
import 'package:larenor/features/kiosk_remote/domain/kiosk_remote_models.dart';
import 'package:larenor/features/kiosk_remote/presentation/kiosk_remote_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const device = KioskRemoteDevice(
  id: '11111111111111111111111111111111',
  revision: 1,
  name: 'Kitchen tablet',
  state: 'active',
);
const pairing = KioskRemotePairing(
  id: '22222222222222222222222222222222',
  deviceId: '11111111111111111111111111111111',
  revision: 1,
  name: 'Home Assistant bridge',
  scopes: ['control', 'read'],
  state: 'active',
  expiresAtMs: 1893456000000,
  mqttClientId: 'larenor-22222222222222222222222222222222',
  mqttTopicPrefix: 'larenor/22222222222222222222222222222222',
);
const snapshot = KioskRemoteSnapshot(devices: [device], pairings: [pairing]);

final class _Api implements KioskRemoteApi {
  Completer<KioskRemoteSnapshot>? loadGate;
  bool retired = false;
  int revokeCalls = 0;
  @override
  Future<KioskRemoteSnapshot> load() =>
      loadGate?.future ?? Future.value(snapshot);
  @override
  Future<KioskRemoteCreated> create(
    KioskRemoteDevice device,
    Set<String> scopes,
  ) async => const KioskRemoteCreated(
    pairing: pairing,
    token: 'synthetic-one-time-token',
  );
  @override
  Future<void> revoke(KioskRemotePairing pairing) async => revokeCalls++;
  @override
  void retire() => retired = true;
}

void main() {
  test(
    'successful Core revoke clears the exact local runtime pairing',
    () async {
      final api = _Api();
      final cleared = <String>[];
      final controller = KioskRemoteController(
        api: api,
        isCurrent: () => true,
        onPairingRevoked: (pairingId) async => cleared.add(pairingId),
      )..snapshot = snapshot;
      addTearDown(controller.dispose);

      await controller.revoke(pairing);

      expect(api.revokeCalls, 1);
      expect(cleared, [pairing.id]);
      expect(controller.snapshot?.pairings, isEmpty);
    },
  );

  test('one-time pairing needs an explicit secure enrollment action', () async {
    final api = _Api();
    KioskRemoteCreated? enrolled;
    final controller = KioskRemoteController(
      api: api,
      isCurrent: () => true,
      onPairingEnrolled: (value) async => enrolled = value,
    )..snapshot = const KioskRemoteSnapshot(devices: [device], pairings: []);
    addTearDown(controller.dispose);

    await controller.create(device, const {'read'});
    expect(controller.oneTimeToken, 'synthetic-one-time-token');
    expect(enrolled, isNull);

    await controller.enrollCreatedPairing();

    expect(enrolled?.pairing.id, pairing.id);
    expect(controller.oneTimeToken, isNull);
    expect(controller.enrolledPairingId, pairing.id);
  });

  testWidgets('tablet enrollment is a separate 48dp confirmation action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var enrollCalls = 0;
    final controller =
        KioskRemoteController(
            api: _Api(),
            isCurrent: () => true,
            onPairingEnrolled: (_) async => enrollCalls++,
          )
          ..snapshot = const KioskRemoteSnapshot(
            devices: [device],
            pairings: [],
          )
          ..state = KioskRemoteViewState.ready;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: KioskRemoteScreen(controller: controller),
      ),
    );

    final pair = find.byKey(
      const ValueKey('kiosk-remote-pair-11111111111111111111111111111111'),
    );
    await tester.scrollUntilVisible(
      pair,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(pair);
    await tester.pumpAndSettle();
    expect(enrollCalls, 0);

    final enroll = find.byKey(const ValueKey('kiosk-remote-enroll'));
    await tester.scrollUntilVisible(
      enroll,
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.getSize(enroll).height, greaterThanOrEqualTo(48));
    await tester.tap(enroll);
    await tester.pumpAndSettle();

    expect(enrollCalls, 1);
    expect(find.byKey(const ValueKey('kiosk-remote-copy')), findsNothing);
    expect(
      find.text(
        'This tablet is securely enrolled for the current Core and account.',
      ),
      findsOneWidget,
    );
  });

  test('late pairing inventory is cleared after route retirement', () async {
    var current = true;
    final api = _Api();
    final controller = KioskRemoteController(
      api: api,
      isCurrent: () => current,
    );
    addTearDown(controller.dispose);
    final gate = Completer<KioskRemoteSnapshot>();
    api.loadGate = gate;
    final pending = controller.load();
    current = false;
    controller.setInteractive(false);
    gate.complete(snapshot);
    await pending;
    expect(controller.state, KioskRemoteViewState.stale);
    expect(controller.snapshot, isNull);
    expect(api.retired, isTrue);
  });

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets('paired remote management $width ${locale.languageCode} 2x', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller =
            KioskRemoteController(api: _Api(), isCurrent: () => true)
              ..snapshot = snapshot
              ..state = KioskRemoteViewState.ready;
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          CupertinoApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: KioskRemoteScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Kitchen tablet'), findsOneWidget);
        final revoke = find.byKey(const ValueKey('remote-pairing-revoke'));
        if (revoke.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            revoke,
            300,
            scrollable: find.byType(Scrollable).first,
          );
        }
        expect(revoke, findsOneWidget);
        expect(tester.getSize(revoke).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
