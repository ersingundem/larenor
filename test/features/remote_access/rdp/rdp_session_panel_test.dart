import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/rdp/rdp_display_geometry.dart';
import 'package:larenor/features/remote_access/rdp/rdp_engine.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_security_store.dart';

import '../remote_profiles_ui_fixture.dart';
import 'rdp_models_test.dart' show fixture, packagedCapabilities;

const _defaultWindow = WindowPolicySnapshot(
  supported: true,
  isResumed: true,
  hasWindowFocus: true,
  displayId: 0,
  displayRevision: 1,
);

WindowPolicySnapshot _externalWindow(int id, int revision) =>
    WindowPolicySnapshot(
      supported: true,
      isResumed: true,
      hasWindowFocus: true,
      isExternalDisplay: true,
      displayId: id,
      displayRevision: revision,
    );

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

class UiChannel
    implements RdpChannel, RdpFrameChannel, RdpNegotiatedInputChannel {
  UiChannel({required this.supportsUnicodeInput});
  @override
  final bool supportsUnicodeInput;
  final doneCompleter = Completer<void>();
  final pointers = <RdpPointerEvent>[];
  final keys = <RdpKeyEvent>[];
  final displays = <RdpDisplaySpec>[];
  final texts = <String>[];
  final clipboards = <String>[];
  final acknowledgements = <int>[];
  final _frames = StreamController<RdpFrame>.broadcast();
  bool clipboardAccepted = true;
  Completer<bool>? clipboardReply;
  @override
  Future<void> get done => doneCompleter.future;
  @override
  Stream<RdpFrame> get frames => _frames.stream;
  bool get hasFrameListener => _frames.hasListener;
  @override
  void close() {
    if (!doneCompleter.isCompleted) doneCompleter.complete();
    if (!_frames.isClosed) unawaited(_frames.close());
  }

  @override
  Future<void> acknowledgeFrame(int sequence) async {
    acknowledgements.add(sequence);
  }

  void frame({int sequence = 1, int width = 160, int height = 90}) {
    _frames.add(
      RdpFrame(
        sequence: sequence,
        width: width,
        height: height,
        dpi: 160,
        stride: width * 4,
        bgra: Uint8List(width * height * 4),
      ),
    );
  }

  @override
  void key(RdpKeyEvent event) => keys.add(event);
  @override
  void pointer(RdpPointerEvent event) => pointers.add(event);
  @override
  void resize(RdpDisplaySpec display) => displays.add(display);
  @override
  void text(String value) => texts.add(value);
  @override
  Future<bool> sendClipboardText(String value) async {
    clipboards.add(value);
    return clipboardReply?.future ?? clipboardAccepted;
  }
}

class UiEngine implements RdpEngine {
  UiEngine({this.supportsIme = false});
  final bool supportsIme;
  late final channel = UiChannel(supportsUnicodeInput: supportsIme);
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
  ui.windows.add(_defaultWindow);
  await tester.pump();
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

Future<void> enableClipboard(WidgetTester tester) async {
  await connectRdp(tester);
  await press(tester, 'rdp-clipboard-clientToRemote');
  await press(tester, 'rdp-settings-save');
  await connectRdp(tester);
}

Future<void> selectDisplayMode(WidgetTester tester, RdpDisplayMode mode) async {
  await press(tester, 'rdp-display-${mode.name}');
  await press(tester, 'rdp-settings-save');
}

Future<void> showFrame(
  WidgetTester tester,
  UiChannel channel, {
  int sequence = 1,
  int width = 160,
  int height = 90,
}) async {
  expect(channel.hasFrameListener, isTrue);
  channel.frame(sequence: sequence, width: width, height: height);
  await tester.pump();
  await tester.runAsync(() async {
    for (
      var attempt = 0;
      attempt < 100 && !channel.acknowledgements.contains(sequence);
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
  await tester.pump();
  expect(channel.acknowledgements, contains(sequence));
}

void main() {
  testWidgets(
    'lost clipboard submission retires once and permits explicit reconnect',
    (tester) async {
      final ui = RemoteUi(), engines = <UiEngine>[];
      await ui.mount(
        tester,
        width: 1280,
        rdpEngine: () {
          final e = UiEngine();
          engines.add(e);
          return e;
        },
        rdpTrust: UiTrust(),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async =>
                call.method == 'Clipboard.getData' ? {'text': 'private'} : null,
          );
      await openRdp(tester, ui);
      await enableClipboard(tester);
      final old = engines.last.channel;
      old.clipboardReply = Completer<bool>();
      await tester.ensureVisible(key('rdp-clipboard-send'));
      await tester.pumpAndSettle();
      await tester.tap(key('rdp-clipboard-send'));
      await tester.pump();
      expect(old.clipboards, ['private']);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(old.doneCompleter.isCompleted, isTrue);
      expect(key('rdp-clipboard-send'), findsNothing);
      expect(find.textContaining('submitted to this session'), findsNothing);
      await press(tester, 'rdp-reconnect');
      await tester.enterText(key('rdp-password'), 'new-password');
      await press(tester, 'rdp-authenticate');
      expect(engines.last.channel, isNot(same(old)));
      old.clipboardReply!.complete(true);
      await tester.pumpAndSettle();
      expect(engines.last.channel.clipboards, isEmpty);
      await press(tester, 'rdp-clipboard-send');
      expect(engines.last.channel.clipboards, ['private']);
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in ['en', 'tr']) {
    testWidgets('$locale clipboard is explicit, scoped and accessible at 2x', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final ui = RemoteUi(), engines = <UiEngine>[];
      await ui.mount(
        tester,
        width: locale == 'en' ? 1280 : 600,
        scale: 2,
        locale: locale,
        rdpEngine: () {
          final engine = UiEngine();
          engines.add(engine);
          return engine;
        },
        rdpTrust: UiTrust(),
      );
      var reads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              reads++;
              expect(call.arguments, Clipboard.kTextPlain);
              return {'text': 'İstanbul\n😀'};
            }
            return null;
          });
      await openRdp(tester, ui);
      await enableClipboard(tester);
      expect(reads, 0);
      expect(engines.expand((e) => e.channel.clipboards), isEmpty);
      expect(
        tester.getSize(key('rdp-clipboard-send')).height,
        greaterThanOrEqualTo(48),
      );
      await press(tester, 'rdp-clipboard-send');
      expect(reads, 1);
      expect(engines.last.channel.clipboards, ['İstanbul\n😀']);
      expect(
        find.textContaining(
          locale == 'en' ? 'submitted to this session' : 'bu oturuma iletildi',
        ),
        findsOneWidget,
      );
      expect(ui.values.values, isNot(contains('İstanbul\n😀')));
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets(
    'clipboard disabled never reads, and native refusal is not success',
    (tester) async {
      final ui = RemoteUi(), engines = <UiEngine>[];
      await ui.mount(
        tester,
        width: 1280,
        rdpEngine: () {
          final e = UiEngine();
          engines.add(e);
          return e;
        },
        rdpTrust: UiTrust(),
      );
      var reads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              reads++;
              return {'text': 'private'};
            }
            return null;
          });
      await openRdp(tester, ui);
      await connectRdp(tester);
      expect(key('rdp-clipboard-send'), findsNothing);
      expect(reads, 0);
      await press(tester, 'rdp-clipboard-clientToRemote');
      await press(tester, 'rdp-settings-save');
      await connectRdp(tester);
      engines.last.channel.clipboardAccepted = false;
      await press(tester, 'rdp-clipboard-send');
      expect(reads, 1);
      expect(find.textContaining('submitted to this session'), findsNothing);
      expect(
        find.textContaining('Check the session before trying again'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final timeout in [false, true]) {
    testWidgets(
      'pending clipboard ${timeout ? 'timeout' : 'foreground retirement'} never sends late data',
      (tester) async {
        final ui = RemoteUi(), engines = <UiEngine>[];
        await ui.mount(
          tester,
          width: 1280,
          rdpEngine: () {
            final e = UiEngine();
            engines.add(e);
            return e;
          },
          rdpTrust: UiTrust(),
        );
        final pending = Completer<Map<String, Object?>?>();
        var reads = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.getData') {
                reads++;
                return pending.future;
              }
              return null;
            });
        await openRdp(tester, ui);
        await enableClipboard(tester);
        await tester.ensureVisible(key('rdp-clipboard-send'));
        await tester.pumpAndSettle();
        await tester.tap(key('rdp-clipboard-send'));
        await tester.pump();
        expect(reads, 1);
        if (timeout) {
          await tester.pump(const Duration(seconds: 6));
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Check the session before trying again'),
            findsOneWidget,
          );
        } else {
          ui.interaction.setActive(false);
          await tester.pumpAndSettle();
          expect(key('rdp-session-panel'), findsNothing);
        }
        pending.complete({'text': 'late-private'});
        await tester.pumpAndSettle();
        expect(engines.expand((e) => e.channel.clipboards), isEmpty);
        expect(find.textContaining('submitted to this session'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

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
    await showFrame(tester, engine.channel);
    expect(key('rdp-surface'), findsOneWidget);
    await tester.ensureVisible(key('rdp-surface'));
    await tester.pumpAndSettle();
    expect(key('rdp-frame-image'), findsOneWidget);
    await tester.tapAt(tester.getCenter(key('rdp-frame-image')));
    tester.widget<Focus>(key('rdp-surface')).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    expect(engine.channel.pointers, isNotEmpty);
    expect(engine.channel.keys, hasLength(2));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.audioVolumeUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
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

  testWidgets('fit letterboxes actual frame and rejects hidden coordinates', (
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
    await connectRdp(tester);
    await showFrame(tester, engine.channel);
    await tester.ensureVisible(key('rdp-surface'));
    await tester.pumpAndSettle();
    final surface = tester.getRect(key('rdp-surface'));
    final frame = tester.getRect(key('rdp-frame-image'));
    expect(frame.width / frame.height, closeTo(16 / 9, .001));
    expect(frame.width, lessThanOrEqualTo(surface.width));
    expect(frame.height, lessThanOrEqualTo(surface.height));

    final hidden = frame.left > surface.left
        ? Offset(surface.left + 1, surface.center.dy)
        : Offset(surface.center.dx, surface.top + 1);
    await tester.tapAt(hidden);
    expect(engine.channel.pointers, isEmpty);
    await tester.tapAt(frame.center);
    expect(engine.channel.pointers.last.x, closeTo(.5, .01));
    expect(engine.channel.pointers.last.y, closeTo(.5, .01));

    for (final cancel in [false, true]) {
      engine.channel.pointers.clear();
      final gesture = await tester.startGesture(
        frame.center,
        pointer: cancel ? 42 : 41,
      );
      await gesture.moveTo(hidden);
      final lastValid = engine.channel.pointers.last;
      final beforeRelease = engine.channel.pointers.length;
      if (cancel) {
        await gesture.cancel();
      } else {
        await gesture.up();
      }
      expect(engine.channel.pointers, hasLength(beforeRelease + 1));
      expect(engine.channel.pointers.last.buttons, 0);
      expect(engine.channel.pointers.last.x, lastValid.x);
      expect(engine.channel.pointers.last.y, lastValid.y);
    }
  });

  testWidgets(
    'fill crops actual frame and inversely maps visible coordinates',
    (tester) async {
      final engine = UiEngine(), ui = RemoteUi();
      await ui.mount(
        tester,
        width: 1280,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, ui);
      await selectDisplayMode(tester, RdpDisplayMode.fillWindow);
      await connectRdp(tester);
      expect(
        engine.requests.single.settings.displayMode,
        RdpDisplayMode.fillWindow,
      );
      await showFrame(tester, engine.channel);
      await tester.ensureVisible(key('rdp-surface'));
      await tester.pumpAndSettle();
      final surface = tester.getRect(key('rdp-surface'));
      final frame = tester.getRect(key('rdp-frame-image'));
      expect(frame.width / frame.height, closeTo(16 / 9, .001));
      expect(frame.width, greaterThanOrEqualTo(surface.width));
      expect(frame.height, greaterThanOrEqualTo(surface.height));
      final local = Offset(surface.width / 2, 1);
      final expected = RdpDisplayGeometry.calculate(
        mode: RdpDisplayMode.fillWindow,
        frameSize: const Size(160, 90),
        viewportSize: surface.size,
        devicePixelRatio: 1,
      ).normalize(local)!;
      await tester.tapAt(surface.topLeft + local);
      expect(engine.channel.pointers.last.x, closeTo(expected.dx, .01));
      expect(engine.channel.pointers.last.y, closeTo(expected.dy, .01));
      expect(expected.dy, greaterThan(0));
    },
  );

  testWidgets(
    'native is one-to-one, explicitly pannable, and never requests DISP resize',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final engine = UiEngine(), ui = RemoteUi();
      await ui.mount(
        tester,
        width: 1280,
        rdpEngine: () => engine,
        rdpTrust: UiTrust(),
      );
      await openRdp(tester, ui);
      await selectDisplayMode(tester, RdpDisplayMode.native);
      await connectRdp(tester);
      await showFrame(tester, engine.channel, width: 1600, height: 900);
      await tester.ensureVisible(key('rdp-surface'));
      await tester.pumpAndSettle();
      expect(
        engine.requests.single.settings.displayMode,
        RdpDisplayMode.native,
      );
      expect(tester.getSize(key('rdp-frame-image')), const Size(1600, 900));
      expect(engine.channel.displays, isEmpty);
      expect(
        tester.getSemantics(key('rdp-native-pan')).label,
        contains('Pan native canvas'),
      );

      final surface = tester.getRect(key('rdp-surface'));
      final before = tester.getTopLeft(key('rdp-frame-image'));
      final remoteDrag = await tester.startGesture(surface.center, pointer: 43);
      await tester.pump();
      expect(engine.channel.pointers.last.buttons, greaterThan(0));
      await tester.tap(key('rdp-native-pan'));
      await tester.pump();
      expect(
        tester.getSemantics(key('rdp-native-pan')).label,
        contains('Resume remote pointer'),
      );
      expect(engine.channel.pointers.last.buttons, 0);
      final releasedCount = engine.channel.pointers.length;
      await remoteDrag.moveBy(const Offset(-40, 0));
      await remoteDrag.up();
      expect(engine.channel.pointers, hasLength(releasedCount));
      engine.channel.pointers.clear();
      await tester.timedDragFrom(
        surface.center,
        const Offset(-120, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(engine.channel.pointers, isEmpty);
      final after = tester.getTopLeft(key('rdp-frame-image'));
      expect(after.dx, lessThan(before.dx));
      expect(after.dy, before.dy);

      await tester.tap(key('rdp-native-pan'));
      await tester.pump();
      await tester.tapAt(surface.center);
      expect(engine.channel.pointers, isNotEmpty);
      expect(engine.channel.pointers.last.x, greaterThan(surface.width / 3200));
      tester.view.physicalSize = const Size(1000, 900);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpAndSettle();
      expect(engine.channel.displays, isEmpty);
      semantics.dispose();
    },
  );

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

  testWidgets('exact display identity change retires without replay', (
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

    ui.windows.add(_externalWindow(4, 1));
    await tester.pumpAndSettle();
    expect(engines, hasLength(1));
    expect(key('rdp-check'), findsOneWidget);

    await connectRdp(tester);
    expect(engines, hasLength(2));
    expect(engines.last.requests.single.display.externalDisplay, isTrue);
    ui.windows.add(_externalWindow(4, 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rdp-surface')), findsOneWidget);
    expect(engines, hasLength(2));

    ui.windows.add(_externalWindow(5, 1));
    await tester.pumpAndSettle();
    expect(key('rdp-check'), findsOneWidget);
    expect(engines, hasLength(2));
    await connectRdp(tester);
    expect(engines, hasLength(3));
    expect(engines.last.requests.single.display.externalDisplay, isTrue);

    // A remove/add lifecycle can reuse a logical display ID. Its new process
    // revision must still fence the old session without reconnecting it.
    ui.windows.add(_externalWindow(5, 2));
    await tester.pumpAndSettle();
    expect(key('rdp-check'), findsOneWidget);
    expect(engines, hasLength(3));

    ui.windows.add(
      const WindowPolicySnapshot(
        supported: true,
        isResumed: true,
        hasWindowFocus: true,
        isExternalDisplay: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(key('rdp-scroll'), const Offset(0, 1200));
    await tester.pumpAndSettle();
    expect(
      find.text('Window control is unavailable on this platform.'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      key('rdp-check'),
      240,
      scrollable: find
          .descendant(of: key('rdp-scroll'), matching: find.byType(Scrollable))
          .first,
    );
    await tester.pumpAndSettle();
    final check = tester.widget<CupertinoButton>(
      find.descendant(
        of: key('rdp-check'),
        matching: find.byType(CupertinoButton),
      ),
    );
    expect(check.onPressed, isNull);
    expect(engines, hasLength(3));
    expect(engines.last.requests, hasLength(1));
  });

  testWidgets('window completion unknown retires without replay', (
    tester,
  ) async {
    final engines = <UiEngine>[];
    final ui = RemoteUi();
    await ui.mount(
      tester,
      width: 1280,
      rdpEngine: () {
        final engine = UiEngine();
        engines.add(engine);
        return engine;
      },
      rdpTrust: UiTrust(),
    );
    await openRdp(tester, ui);
    await connectRdp(tester);
    expect(engines.single.requests, hasLength(1));

    // WindowPolicyBridge emits this final unknown snapshot before its native
    // stream closes. The provider then retains the safe value, not the tuple.
    ui.windows.add(WindowPolicySnapshot.unknown);
    await tester.pumpAndSettle();
    expect(engines.single.channel.doneCompleter.isCompleted, isTrue);
    expect(engines, hasLength(1));
    expect(engines.single.requests, hasLength(1));
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

      ui.windows.add(_externalWindow(4, 1));
      await tester.pump();
      engine.release.complete();
      await tester.pumpAndSettle();
      expect(engine.requests, isEmpty);
      expect(key('rdp-check'), findsOneWidget);
    },
  );
}
