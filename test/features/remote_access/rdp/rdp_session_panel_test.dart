import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/rdp/rdp_engine.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_security_store.dart';

import '../remote_profiles_ui_fixture.dart';
import 'rdp_models_test.dart' show fixture;

class UiTrust implements RdpTrustStore {
  final pin = RdpCertificatePin.fromJson(fixture()['certificate']);
  @override
  Future<void> checkProfile(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async {}
  @override
  Future<RdpCertificatePin?> readPin(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async => pin;
  @override
  Future<void> trust(
    RemoteProfile profile,
    RdpCertificatePin value, {
    required bool Function() isCurrent,
  }) async {}
}

class UiChannel implements RdpChannel {
  final doneCompleter = Completer<void>();
  final pointers = <RdpPointerEvent>[];
  final keys = <RdpKeyEvent>[];
  final displays = <RdpDisplaySpec>[];
  @override
  Future<void> get done => doneCompleter.future;
  @override
  void close() {
    if (!doneCompleter.isCompleted) doneCompleter.complete();
  }

  @override
  void key(RdpKeyEvent event) => keys.add(event);
  @override
  void pointer(RdpPointerEvent event) => pointers.add(event);
  @override
  void resize(RdpDisplaySpec display) => displays.add(display);
}

class UiEngine implements RdpEngine {
  final channel = UiChannel();
  @override
  Future<RdpCapabilities> capabilities({
    required bool Function() isCurrent,
  }) async => RdpCapabilities.fromJson(fixture()['availableCapabilities']);
  @override
  Future<RdpPeerSecurity> inspect(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async => RdpPeerSecurity(
    tls: true,
    requiresNla: false,
    certificate: RdpCertificatePin.fromJson(fixture()['certificate']),
  );
  @override
  Future<RdpChannel> open(
    RdpSessionRequest request, {
    required RdpCredential? credential,
    required bool Function() isCurrent,
  }) async => channel;
  @override
  void close() {}
}

Future<void> openRdp(WidgetTester tester, RemoteUi ui) async {
  await ui.edit(tester, name: 'Office PC');
  await press(tester, 'remote-protocol-rdp');
  await ui.save(tester);
  await ui.openFirst(tester);
  await press(tester, 'remote-rdp-open');
}

void main() {
  testWidgets('tablet panel exposes unavailable native engine honestly', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final ui = RemoteUi();
    await ui.mount(tester, width: 1280, scale: 2);
    await openRdp(tester, ui);

    expect(find.byKey(const ValueKey('rdp-session-panel')), findsOneWidget);
    expect(find.text('Clipboard: Off'), findsOneWidget);
    expect(find.text('Audio: Off'), findsOneWidget);
    expect(find.text('Files: Off'), findsOneWidget);
    await press(tester, 'rdp-check');
    await tester.fling(key('rdp-scroll'), const Offset(0, 2000), 5000);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('native RDP engine is not packaged'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('rdp-connect')), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('Turkish 2x panel closes when PIN or idle scope retires', (
    tester,
  ) async {
    final ui = RemoteUi();
    await ui.mount(tester, width: 600, scale: 2, locale: 'tr');
    await openRdp(tester, ui);
    expect(find.text('Pano: Kapalı'), findsOneWidget);
    ui.interaction.setActive(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rdp-session-panel')), findsNothing);
    expect(find.byKey(const ValueKey('rdp-password')), findsNothing);
  });

  testWidgets(
    'personal gateway display keyboard and clipboard settings persist',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final ui = RemoteUi();
      await ui.mount(tester, width: 1280, scale: 2);
      await openRdp(tester, ui);

      await tester.enterText(key('rdp-settings-domain'), 'LARENOR');
      await tester.enterText(
        key('rdp-settings-gateway-host'),
        'gateway.home.arpa',
      );
      await tester.enterText(key('rdp-settings-gateway-port'), '443');
      await tester.enterText(key('rdp-settings-gateway-user'), 'gateway-user');
      await press(tester, 'rdp-keyboard-turkishQ');
      await press(tester, 'rdp-clipboard-clientToRemote');
      await press(tester, 'rdp-settings-save');
      expect(find.text('RDP settings saved.'), findsOneWidget);

      expect(
        tester.getSize(key('rdp-settings-save')).height,
        greaterThanOrEqualTo(48),
      );
      await press(tester, 'rdp-back');
      await press(tester, 'remote-rdp-open');
      expect(
        tester
            .widget<CupertinoTextField>(key('rdp-settings-domain'))
            .controller!
            .text,
        'LARENOR',
      );
      expect(
        tester
            .widget<CupertinoTextField>(key('rdp-settings-gateway-host'))
            .controller!
            .text,
        'gateway.home.arpa',
      );
      expect(find.textContaining('Turkish Q'), findsOneWidget);
      expect(find.textContaining('Device to remote'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('connected DeX surface forwards pointer keyboard and resize', (
    tester,
  ) async {
    final engine = UiEngine(), ui = RemoteUi();
    await ui.mount(
      tester,
      width: 1280,
      rdpEngine: () => engine,
      rdpTrust: UiTrust(),
    );
    await openRdp(tester, ui);
    await press(tester, 'rdp-check');
    expect(key('rdp-surface'), findsOneWidget);
    await tester.tap(key('rdp-surface'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    expect(engine.channel.pointers, isNotEmpty);
    expect(engine.channel.keys, hasLength(2));
    tester.view.physicalSize = const Size(1000, 900);
    await tester.pumpAndSettle();
    expect(engine.channel.displays, isNotEmpty);
  });
}
