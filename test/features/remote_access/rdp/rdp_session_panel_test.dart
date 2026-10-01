import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/rdp/rdp_engine.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_security_store.dart';

import '../remote_profiles_ui_fixture.dart';
import 'rdp_models_test.dart' show fixture, packagedCapabilities;

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
  final texts = <String>[];
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
  @override
  void text(String value) => texts.add(value);
}

class UiEngine implements RdpEngine {
  UiEngine({this.supportsIme = false});
  final bool supportsIme;
  final channel = UiChannel();
  final requests = <RdpSessionRequest>[];
  int capabilityReads = 0;
  @override
  Future<RdpCapabilities> capabilities({
    required bool Function() isCurrent,
  }) async {
    capabilityReads++;
    return RdpCapabilities.fromJson(packagedCapabilities(ime: supportsIme));
  }

  @override
  Future<RdpCertificateProbe> inspect(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async => RdpCertificateProbe(
    tlsCertificateObserved: true,
    clientRequiresNla: true,
    certificate: RdpCertificatePin.fromJson(fixture()['certificate']),
  );
  @override
  Future<RdpChannel> open(
    RdpSessionRequest request, {
    required RdpCredential? credential,
    required bool Function() isCurrent,
  }) async {
    if (credential == null) throw const RdpFailure('invalid_credential');
    requests.add(request);
    return channel;
  }

  @override
  void close() {}
}

class HeldCapabilityEngine extends UiEngine {
  final release = Completer<void>();

  @override
  Future<RdpCapabilities> capabilities({
    required bool Function() isCurrent,
  }) async {
    capabilityReads++;
    await release.future;
    return RdpCapabilities.fromJson(packagedCapabilities());
  }
}

Future<void> openRdp(WidgetTester tester, RemoteUi ui) async {
  await ui.edit(tester, name: 'Office PC');
  await press(tester, 'remote-protocol-rdp');
  await ui.save(tester);
  await ui.openFirst(tester);
  await press(tester, 'remote-rdp-open');
}

Future<void> connectRdp(WidgetTester tester) async {
  await press(tester, 'rdp-check');
  if (key('rdp-password').evaluate().isNotEmpty) {
    await tester.enterText(key('rdp-password'), 'one-time-password');
    await press(tester, 'rdp-authenticate');
  }
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
    await connectRdp(tester);
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
      final engine = UiEngine(), ui = RemoteUi();
      await ui.mount(
        tester,
        width: 1280,
        scale: 2,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, ui);

      await connectRdp(tester);

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
      expect(find.text('Clipboard: Device to remote ✓'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  for (final locale in ['en', 'tr']) {
    final width = locale == 'en' ? 1280.0 : 600.0;
    testWidgets('$locale composed text is accessible at 2x', (tester) async {
      final semantics = tester.ensureSemantics();
      final engine = UiEngine(supportsIme: true), ui = RemoteUi();
      await ui.mount(
        tester,
        width: width,
        scale: 2,
        locale: locale,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, ui);
      await connectRdp(tester);
      await tester.ensureVisible(key('rdp-text-input'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          locale == 'tr'
              ? 'Uzak masaüstüne gönderilecek metin'
              : 'Type text for the remote desktop',
        ),
        findsOneWidget,
      );
      expect(
        tester.getSize(key('rdp-text-send')).height,
        greaterThanOrEqualTo(48),
      );
      await tester.enterText(key('rdp-text-input'), 'İstanbul');
      await press(tester, 'rdp-text-send');
      expect(engine.channel.texts, ['İstanbul']);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets('connected DeX surface forwards pointer keyboard and resize', (
    tester,
  ) async {
    final engine = UiEngine(supportsIme: true), ui = RemoteUi();
    await ui.mount(
      tester,
      width: 1280,
      rdpEngine: () => engine,
      rdpTrust: UiTrust(),
    );
    await openRdp(tester, ui);
    await connectRdp(tester);
    expect(key('rdp-surface'), findsOneWidget);
    await tester.ensureVisible(key('rdp-surface'));
    await tester.pumpAndSettle();
    await tester.tap(key('rdp-surface'));
    tester.widget<Focus>(key('rdp-surface')).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    expect(engine.channel.pointers, isNotEmpty);
    expect(engine.channel.keys, hasLength(2));
    await tester.enterText(key('rdp-text-input'), 'İstanbul');
    await press(tester, 'rdp-text-send');
    expect(engine.channel.texts, ['İstanbul']);
    expect(
      tester.widget<CupertinoTextField>(key('rdp-text-input')).controller!.text,
      isEmpty,
    );
    tester.view.physicalSize = const Size(1000, 900);
    await tester.pumpAndSettle();
    expect(engine.channel.displays, isNotEmpty);
  });

  testWidgets('packaged capabilities hide unavailable IME and clipboard mode', (
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
    expect(key('rdp-clipboard-bidirectional'), findsNothing);
    await connectRdp(tester);
    expect(key('rdp-text-input'), findsNothing);
    expect(key('rdp-text-send'), findsNothing);
    expect(key('rdp-clipboard-clientToRemote'), findsOneWidget);
    expect(key('rdp-clipboard-bidirectional'), findsNothing);
  });

  testWidgets('persisted bidirectional mode requires explicit correction', (
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
    await press(tester, 'rdp-back');
    final saved = await ui.read();
    await RdpSecurityStore().saveSettings(
      saved.profiles.single,
      const RdpProfileSettings(clipboardMode: RdpClipboardMode.bidirectional),
      isCurrent: () => true,
    );
    await press(tester, 'remote-rdp-open');
    await connectRdp(tester);

    expect(key('rdp-clipboard-bidirectional'), findsOneWidget);
    expect(
      tester
          .widget<CupertinoButton>(
            find.descendant(
              of: key('rdp-clipboard-bidirectional'),
              matching: find.byType(CupertinoButton),
            ),
          )
          .onPressed,
      isNull,
    );
    expect(key('rdp-clipboard-correction-required'), findsOneWidget);
    expect(
      find.textContaining('saved clipboard mode is unavailable'),
      findsOneWidget,
    );
    await press(tester, 'rdp-settings-save');
    expect(find.text('RDP settings could not be verified.'), findsOneWidget);
    expect(
      (await RdpSecurityStore().readSettings(
        saved.profiles.single,
        isCurrent: () => true,
      )).clipboardMode,
      RdpClipboardMode.bidirectional,
    );
    await press(tester, 'rdp-clipboard-disabled');
    expect(key('rdp-clipboard-correction-required'), findsNothing);
    await press(tester, 'rdp-settings-save');
    expect(
      (await RdpSecurityStore().readSettings(
        saved.profiles.single,
        isCurrent: () => true,
      )).clipboardMode,
      RdpClipboardMode.disabled,
    );
  });

  testWidgets('external display classification change retires without replay', (
    tester,
  ) async {
    final engines = <UiEngine>[];
    RdpEngine factory() {
      final engine = UiEngine();
      engines.add(engine);
      return engine;
    }

    final ui = RemoteUi();
    await ui.mount(
      tester,
      width: 1280,
      rdpEngine: factory,
      rdpTrust: UiTrust(),
    );
    await openRdp(tester, ui);
    await connectRdp(tester);
    expect(engines.single.requests.single.display.externalDisplay, isFalse);

    ui.windows.add(
      const WindowPolicySnapshot(
        supported: true,
        isResumed: true,
        hasWindowFocus: true,
        isExternalDisplay: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(engines, hasLength(1));
    expect(key('rdp-check'), findsOneWidget);

    await connectRdp(tester);
    expect(engines, hasLength(2));
    expect(engines.last.requests.single.display.externalDisplay, isTrue);
    ui.windows.add(
      const WindowPolicySnapshot(
        supported: true,
        isResumed: true,
        hasWindowFocus: true,
        isExternalDisplay: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rdp-surface')), findsOneWidget);
    expect(engines, hasLength(2));
  });

  testWidgets(
    'display classification change during capability read cannot open transport',
    (tester) async {
      final engine = HeldCapabilityEngine(), ui = RemoteUi();
      await ui.mount(
        tester,
        width: 1280,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, ui);
      held(tester, 'rdp-check')();
      await tester.pump();
      expect(engine.capabilityReads, 1);

      ui.windows.add(
        const WindowPolicySnapshot(
          supported: true,
          isResumed: true,
          hasWindowFocus: true,
          isExternalDisplay: true,
        ),
      );
      await tester.pump();
      engine.release.complete();
      await tester.pumpAndSettle();
      expect(engine.requests, isEmpty);
      expect(key('rdp-check'), findsOneWidget);
    },
  );
}
