import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/kiosk/data/kiosk_peripheral_runtime.dart';
import 'package:larenor/features/kiosk/domain/kiosk_peripheral_contract.dart';
import 'package:larenor/features/kiosk/presentation/kiosk_peripheral_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _authority = KioskPeripheralAuthority(
  deviceRevision: 7,
  policyRevision: 11,
  sessionEpoch: 13,
  routeEpoch: 17,
  lifecycleEpoch: 19,
);

Map<String, Object?> _provider(String id, String kind, {bool ready = true}) => {
  'providerId': id,
  'kind': kind,
  'revision': 3,
  'supported': ready,
  'enabledByUser': false,
  'permission': 'granted',
  'connected': true,
  'requiresGms': false,
  'maxPayloadBytes': const {'tts', 'print'}.contains(kind) ? 0 : 512,
};

Map<String, Object?> _inventory({bool ready = true}) => {
  'schemaVersion': 1,
  'inventoryRevision': 5,
  'providers': [
    _provider('qr.local', 'qr', ready: ready),
    _provider('nfc.local', 'nfc', ready: ready),
    _provider('ble.local', 'ble', ready: ready),
    _provider('usb.local', 'usb', ready: ready),
    _provider('tts.local', 'tts', ready: ready),
    _provider('print.local', 'print', ready: ready),
  ],
};

Map<String, Object?> _event() => {
  'schemaVersion': 1,
  'eventId': '0123456789abcdef0123456789abcdef',
  'providerId': 'nfc.local',
  'kind': 'nfc',
  'capabilityRevision': 3,
  'deviceRevision': 7,
  'policyRevision': 11,
  'sessionEpoch': 13,
  'routeEpoch': 17,
  'lifecycleEpoch': 19,
  'sequence': 1,
  'capturedAtElapsedMs': 49000,
  'payload': 'javascript:alert(1)',
};

class _Store implements KioskPeripheralOptInStore {
  Set<String> value = {};
  int saves = 0;
  @override
  Future<Set<String>> read() async => {...value};
  @override
  Future<void> save(Set<String> ids) async {
    saves++;
    value = {...ids};
  }
}

class _Runtime
    implements KioskPeripheralRuntime, KioskPeripheralRetirementRuntime {
  _Runtime({this.ready = true});
  bool ready;
  int reads = 0;
  int consumes = 0;
  int retires = 0;
  Completer<Object?>? pending;
  @override
  int nowElapsedMs() => 50000;
  @override
  Future<KioskPeripheralRuntimeSnapshot> snapshot() async {
    reads++;
    return KioskPeripheralRuntimeSnapshot(
      rawInventory: _inventory(ready: ready),
      authority: _authority,
      gmsAvailable: false,
    );
  }

  @override
  Future<Object?> takeNextInput(String providerId) async {
    consumes++;
    return pending?.future ?? _event();
  }

  @override
  Future<void> retire() async {
    retires++;
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Runtime runtime,
  _Store store, {
  Size size = const Size(600, 1000),
  double scale = 1,
  Locale locale = const Locale('en'),
  AppInteractionController? interaction,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CupertinoApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: interaction == null
            ? KioskPeripheralScreen(runtime: runtime, optInStore: store)
            : AppInteractionScope(
                controller: interaction,
                child: KioskPeripheralScreen(
                  runtime: runtime,
                  optInStore: store,
                ),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('native inventory cannot advertise an unwired input adapter', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('com.ersingundem.larenor/kiosk_peripherals');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      return call.method == 'capabilities' ? _inventory() : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final runtime = AndroidKioskPeripheralRuntime(
      channel: channel,
      isAndroid: true,
    );
    final snapshot = await runtime.snapshot();
    final inventory = KioskPeripheralInventory.fromChannel(
      snapshot.rawInventory,
      gmsAvailable: snapshot.gmsAvailable,
    );
    expect(snapshot.authority, isNull);
    expect(
      inventory.providers.every((provider) => !provider.supported),
      isTrue,
    );
    expect(await runtime.takeNextInput('qr.local'), isNull);
    await runtime.retire();
    expect(methods, ['capabilities', 'retire']);
  });

  test('unacknowledged native retirement fences every later arm until acknowledged', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel(
      'com.ersingundem.larenor/kiosk_peripherals-retirement',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final firstRetirement = Completer<void>();
    final methods = <String>[];
    var retirements = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'capabilities') {
        return {
          'schemaVersion': 1,
          'gmsAvailable': false,
          'inventory': _inventory(),
        };
      }
      if (call.method == 'retire' && retirements++ == 0) {
        await firstRetirement.future;
        return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final runtime = AndroidKioskPeripheralRuntime(
      channel: channel,
      isAndroid: true,
      retirementTimeout: const Duration(milliseconds: 1),
    );

    expect((await runtime.snapshot()).authority, isNotNull);
    await runtime.retire();
    firstRetirement.complete();
    await Future<void>.delayed(Duration.zero);

    expect((await runtime.snapshot()).authority, isNull);
    expect(await runtime.takeNextInput('nfc.local'), isNull);
    expect(await runtime.requestProviderPermission('ble.gatt'), isFalse);
    expect(methods, ['capabilities', 'retire']);

    await runtime.retire();
    expect((await runtime.snapshot()).authority, isNotNull);
    expect(methods, ['capabilities', 'retire', 'retire', 'capabilities']);
  });

  test(
    'late capabilities from a retired route cannot arm or clear its successor',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel(
        'com.ersingundem.larenor/kiosk_peripherals-generation',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final oldReply = Completer<Object?>();
      final oldRequested = Completer<void>();
      var capabilityCalls = 0;
      final methods = <String>[];
      final armEpochs = <int>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'capabilities') {
          if (capabilityCalls++ == 0) {
            oldRequested.complete();
            return oldReply.future;
          }
          return {
            'schemaVersion': 1,
            'gmsAvailable': false,
            'inventory': _inventory(),
          };
        }
        if (call.method == 'takeNextInput') {
          armEpochs.add((call.arguments as Map)['routeEpoch'] as int);
          return {'input': _event(), 'nowElapsedMs': 50000};
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final runtime = AndroidKioskPeripheralRuntime(
        channel: channel,
        isAndroid: true,
      );
      final oldSnapshot = runtime.snapshot();
      await oldRequested.future;
      await runtime.retire();
      final successor = await runtime.snapshot();
      expect(successor.authority, isNotNull);
      oldReply.complete({
        'schemaVersion': 1,
        'gmsAvailable': false,
        'inventory': _inventory(),
      });
      expect((await oldSnapshot).authority, isNull);
      expect(await runtime.takeNextInput('nfc.local'), isNotNull);
      expect(armEpochs, [successor.authority!.routeEpoch]);
      expect(methods, [
        'capabilities',
        'retire',
        'capabilities',
        'takeNextInput',
      ]);
    },
  );
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets('${locale.languageCode} $width 2x lists distinct providers', (
        tester,
      ) async {
        final runtime = _Runtime(ready: false);
        await _mount(
          tester,
          runtime,
          _Store(),
          size: Size(width, 1000),
          scale: 2,
          locale: locale,
        );
        expect(
          find.byKey(const ValueKey('peripheral-qr.local')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('peripheral-print.local')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('peripheral-consume-qr.local')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        expect(runtime.consumes, 0);
      });
    }
  }

  testWidgets('opt-in persists but unsupported adapter cannot consume', (
    tester,
  ) async {
    final runtime = _Runtime(ready: false);
    final store = _Store();
    await _mount(tester, runtime, store);
    await tester.tap(find.byKey(const ValueKey('peripheral-toggle-qr.local')));
    await tester.pumpAndSettle();
    expect(store.value, {'qr.local'});
    expect(store.saves, 1);
    expect(runtime.consumes, 0);
    expect(
      find.byKey(const ValueKey('peripheral-consume-qr.local')),
      findsNothing,
    );
  });

  testWidgets('tablet toggle exposes a readable label and 48dp target', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final runtime = _Runtime(ready: false);
    final store = _Store()..value = {'qr.local'};
    await _mount(tester, runtime, store);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == 'QR scanner. No working adapter on this tablet. Choice enabled on this tablet. Android permission granted. Device connected',
      ),
      findsOneWidget,
    );
    final toggle = find.byKey(const ValueKey('peripheral-toggle-qr.local'));
    final size = tester.getSize(toggle);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'QR scanner. Disable choice',
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('review only consumes on explicit tap and never executes', (
    tester,
  ) async {
    final runtime = _Runtime();
    final store = _Store()..value = {'nfc.local'};
    await _mount(tester, runtime, store);
    expect(runtime.consumes, 0);
    await tester.tap(
      find.byKey(const ValueKey('peripheral-consume-nfc.local')),
    );
    await tester.pumpAndSettle();
    expect(runtime.consumes, 1);
    expect(find.text('javascript:alert(1)'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('peripheral-review-only')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('peripheral-consume-nfc.local')),
    );
    await tester.pumpAndSettle();
    expect(runtime.consumes, 2);
    expect(find.text('javascript:alert(1)'), findsNothing);
  });

  testWidgets('route disposal drops late input without review', (tester) async {
    final runtime = _Runtime()..pending = Completer<Object?>();
    final store = _Store()..value = {'nfc.local'};
    await _mount(tester, runtime, store);
    await tester.tap(
      find.byKey(const ValueKey('peripheral-consume-nfc.local')),
    );
    await tester.pump();
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    await tester.pump();
    expect(runtime.retires, greaterThan(0));
    runtime.pending!.complete(_event());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'interaction expiry drops late input and does not revive review',
    (tester) async {
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      final runtime = _Runtime()..pending = Completer<Object?>();
      final store = _Store()..value = {'nfc.local'};
      await _mount(tester, runtime, store, interaction: interaction);
      await tester.tap(
        find.byKey(const ValueKey('peripheral-consume-nfc.local')),
      );
      await tester.pump();
      interaction.setActive(false);
      runtime.pending!.complete(_event());
      await tester.pumpAndSettle();
      expect(find.text('javascript:alert(1)'), findsNothing);
      interaction.setActive(true);
      await tester.pumpAndSettle();
      expect(find.text('javascript:alert(1)'), findsNothing);
      expect(runtime.consumes, 1);
    },
  );

  testWidgets('covering route retires reviewed input before return', (
    tester,
  ) async {
    final runtime = _Runtime();
    final store = _Store()..value = {'nfc.local'};
    await _mount(tester, runtime, store);
    await tester.tap(
      find.byKey(const ValueKey('peripheral-consume-nfc.local')),
    );
    await tester.pumpAndSettle();
    expect(find.text('javascript:alert(1)'), findsOneWidget);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(CupertinoPageRoute<void>(builder: (_) => const SizedBox()));
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('javascript:alert(1)'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
