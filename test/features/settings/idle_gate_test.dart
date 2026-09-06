// Retained AsyncValue fixtures reproduce configuration refreshes.
// ignore_for_file: invalid_use_of_internal_member
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/ambient/providers/ambient_providers.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/presentation/widgets/entity_controls.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/ha_tools/domain/ha_action.dart';
import 'package:larenor/features/ha_tools/presentation/ha_actions_screen.dart';
import 'package:larenor/features/media/local_audio/presentation/local_audio_screen.dart';
import 'package:larenor/features/media/local_audio/providers/local_audio_providers.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_guest.dart';
import 'package:larenor/features/proxmox/data/proxmox_client.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';
import 'package:larenor/features/proxmox/presentation/widgets/proxmox_guest_row.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/features/settings/presentation/idle_gate.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/features/wellbeing/providers/wellbeing_providers.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_disclosure_policy.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../media/local_audio/local_audio_ui_fixture.dart';

const _config = HaConnectionConfig(
  baseUrl: 'https://fixture.invalid',
  token: 'fixture',
);
const _weather = HaEntity(
  entityId: 'weather.home',
  state: 'sunny',
  attributes: {'temperature': 23},
);
const _lock = HaEntity(
  entityId: 'lock.front',
  state: 'locked',
  attributes: {'friendly_name': 'Front lock'},
);

class _Idle extends IdleMode {
  @override
  Future<IdleModeSettings> build() async =>
      const IdleModeSettings(enabled: true, timeoutMinutes: 1);
  void replace(AsyncValue<IdleModeSettings> next) => state = next;
}

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => _config;
  void replace(AsyncValue<HaConnectionConfig?> next) => state = next;
}

class _Entities extends Entities {
  @override
  Future<Map<String, HaEntity>> build() async => {
    _weather.entityId: _weather,
    _lock.entityId: _lock,
  };
  void replace(AsyncValue<Map<String, HaEntity>> next) => state = next;
}

const _proxmoxConfig = ProxmoxConfig(
  host: 'proxmox.invalid',
  port: 8006,
  username: 'fixture',
  realm: 'pam',
  password: 'fixture',
  allowSelfSigned: false,
);

class _ProxmoxConnection extends ProxmoxConnection {
  @override
  Future<ProxmoxConfig?> build() async => _proxmoxConfig;
}

class _ProxmoxClient extends ProxmoxClient {
  _ProxmoxClient()
    : super(
        config: _proxmoxConfig,
        httpClient: MockClient((_) async => http.Response('unexpected', 500)),
      );
  int writes = 0;
  @override
  bool get isAuthenticated => true;
  @override
  Future<String> powerAction(
    String node,
    ProxmoxGuestType type,
    int vmid,
    String action,
  ) async {
    writes++;
    return 'UPID:fixture';
  }
}

class _Probe extends StatefulWidget {
  const _Probe({super.key});
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with SingleTickerProviderStateMixin {
  late final AnimationController ticker;
  final focus = FocusNode();
  int commands = 0, clicks = 0, scrolls = 0, pans = 0, ticks = 0;
  @override
  void initState() {
    super.initState();
    ticker =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..addListener(() => ticks++)
          ..repeat();
  }

  @override
  void dispose() {
    ticker.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focus,
    autofocus: true,
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.enter) {
        commands++;
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Listener(
      onPointerSignal: (_) => scrolls++,
      onPointerPanZoomStart: (_) => pans++,
      child: CupertinoPageScaffold(
        child: Center(
          child: Semantics(
            label: 'underlying action',
            child: CupertinoButton(
              onPressed: () => clicks++,
              child: const Text('Command'),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Harness {
  final idle = _Idle();
  final connection = _Connection();
  final entities = _Entities();
  late ProviderContainer container;
  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    List<Override> overrides = const [],
    Size size = const Size(700, 900),
    double scale = 1,
    HaRestClient? restClient,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      overrides: [
        idleModeProvider.overrideWith(() => idle),
        connectionConfigProvider.overrideWith(() => connection),
        entitiesProvider.overrideWith(() => entities),
        haWebSocketClientProvider.overrideWith((_) => null),
        haRestClientProvider.overrideWith((_) => restClient),
        ...overrides,
      ],
    );
    addTearDown(container.dispose);
    final entityLease = container.listen(entitiesProvider, (_, _) {});
    final configLease = container.listen(connectionConfigProvider, (_, _) {});
    addTearDown(entityLease.close);
    addTearDown(configLease.close);
    // The real privacy providers now wait behind the same configuration queue
    // as ambient preferences. Establish a confirmed local baseline before
    // exercising idle and stale HA states; never override the privacy result.
    await container.read(ambientSettingsProvider.future);
    await container.read(wellbeingSettingsProvider.future);
    await container.read(wellbeingDisclosureProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: IdleGate(child: child!),
          ),
          home: child,
        ),
      ),
    );
    await frames(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await frames(tester);
  }
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

Finder get clock => find.byWidgetPredicate(
  (w) => w is Text && RegExp(r'^\d{2}:\d{2}$').hasMatch(w.data ?? ''),
);
Future<void> sleep(WidgetTester tester) async {
  await tester.pump(const Duration(minutes: 1));
  await frames(tester);
  expect(clock, findsOneWidget);
}

Future<void> wake(WidgetTester tester) async {
  await tester.tap(clock);
  await frames(tester);
  expect(clock, findsNothing);
}

void _pause(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void _resume(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  void focus(WidgetTester tester, ViewFocusState state, {int? viewId}) =>
      tester.binding.handleViewFocusChanged(ViewFocusEvent(
        viewId: viewId ?? tester.view.viewId,
        state: state,
        direction: ViewFocusDirection.undefined,
      ));

  testWidgets('native focus loss suspends UI and retires its old interaction epoch', (tester) async {
    final h = _Harness();
    final key = GlobalKey<_ProbeState>();
    await h.mount(tester, _Probe(key: key));
    final state = key.currentState!;
    final interaction = AppInteractionScope.maybeRead(tester.element(find.byType(_Probe)))!;
    final epoch = interaction.epoch;
    focus(tester, ViewFocusState.unfocused);
    expect(interaction.active, isFalse);
    expect(interaction.epoch, greaterThan(epoch));
    await frames(tester);
    final ticks = state.ticks;
    await tester.pump(const Duration(minutes: 2));
    expect(state.ticks, ticks);
    expect(clock, findsNothing);
    expect(key.currentState, same(state));
    // A background pointer event cannot reopen this window's interaction.
    tester.binding.handlePointerEvent(const PointerScrollEvent(position: Offset(100, 100), scrollDelta: Offset(0, 1)));
    await frames(tester);
    expect(interaction.active, isFalse);
    focus(tester, ViewFocusState.focused);
    await frames(tester);
    expect(interaction.active, isTrue);
    expect(interaction.epoch, greaterThan(epoch));
    expect(key.currentState, same(state));
    await sleep(tester);
    await h.close(tester);
  });

  testWidgets('another view focus does not suspend this tablet window', (tester) async {
    final h = _Harness();
    await h.mount(tester, const _Probe());
    final interaction = AppInteractionScope.maybeRead(tester.element(find.byType(_Probe)))!;
    final epoch = interaction.epoch;
    focus(tester, ViewFocusState.unfocused, viewId: tester.view.viewId + 1);
    expect(interaction.active, isTrue);
    expect(interaction.epoch, epoch);
    await sleep(tester);
    await h.close(tester);
  });

  testWidgets('native focus roundtrip cannot reuse a root HA confirmation', (tester) async {
    final h = _Harness();
    final requests = <http.Request>[];
    final client = HaRestClient(baseUrl: _config.baseUrl, token: 'fixture',
      httpClient: MockClient((request) async { requests.add(request); return http.Response('[]', 200); }));
    addTearDown(client.dispose);
    await h.mount(tester,
      const CupertinoPageScaffold(child: EntityControls(entity: _lock)),
      restClient: client, overrides: [haActionsProvider.overrideWith((_) async => [
        const HaAction(domain: 'lock', service: 'unlock', metadata: {'target': <String, dynamic>{}}),
      ])]);
    await tester.tap(find.byKey(const ValueKey('entity-control-unlock')));
    await frames(tester);
    await tester.pump(const Duration(milliseconds: 400));
    final old = tester.widget<CupertinoDialogAction>(find.widgetWithText(CupertinoDialogAction, 'Unlock')).onPressed!;
    focus(tester, ViewFocusState.unfocused);
    await frames(tester);
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    focus(tester, ViewFocusState.focused);
    await frames(tester);
    old();
    await frames(tester);
    expect(requests, isEmpty);
    expect(tester.takeException(), isNull);
    await h.close(tester);
  });
  for (final privacy in <AsyncValue<Set<String>>>[
    const AsyncData({'weather.home'}),
    const AsyncLoading(),
    AsyncError(StateError('private-filter'), StackTrace.empty),
  ]) {
    testWidgets(
      'idle weather respects private binding filter ${privacy.runtimeType}',
      (tester) async {
        final h = _Harness();
        await h.mount(
          tester,
          const SizedBox.expand(),
          overrides: [
            wellbeingPrivateEntityIdsProvider.overrideWithValue(privacy),
          ],
        );
        await sleep(tester);
        expect(find.text('23° · sunny'), findsNothing);
        expect(find.textContaining('private-filter'), findsNothing);
        await h.close(tester);
      },
    );
  }
  testWidgets(
    'HA root confirmation expires on idle and old callback cannot unlock after wake',
    (tester) async {
      final h = _Harness();
      final requests = <http.Request>[];
      final client = HaRestClient(
        baseUrl: _config.baseUrl,
        token: 'fixture',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('[]', 200);
        }),
      );
      addTearDown(client.dispose);
      await h.mount(
        tester,
        const CupertinoPageScaffold(child: EntityControls(entity: _lock)),
        restClient: client,
        overrides: [
          haActionsProvider.overrideWith(
            (_) async => [
              const HaAction(
                domain: 'lock',
                service: 'unlock',
                metadata: {'target': <String, dynamic>{}},
              ),
            ],
          ),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('entity-control-unlock')));
      await frames(tester);
      await tester.pump(const Duration(milliseconds: 400));
      final old = tester
          .widget<CupertinoDialogAction>(
            find.widgetWithText(CupertinoDialogAction, 'Unlock'),
          )
          .onPressed!;
      await sleep(tester);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      await wake(tester);
      old();
      await frames(tester);
      expect(requests, isEmpty);
      expect(tester.takeException(), isNull);
      await h.close(tester);
    },
  );

  testWidgets(
    'Proxmox root power sheet expires on idle and old callback cannot run after wake',
    (tester) async {
      final h = _Harness();
      final client = _ProxmoxClient();
      addTearDown(client.dispose);
      await h.mount(
        tester,
        CupertinoPageScaffold(
          child: Center(
            child: ProxmoxGuestRow(
              guest: const ProxmoxGuest(
                vmid: 100,
                name: 'Fixture guest',
                type: ProxmoxGuestType.qemu,
                node: 'pve',
                status: 'running',
              ),
              onChanged: () {},
            ),
          ),
        ),
        overrides: [
          proxmoxConnectionProvider.overrideWith(_ProxmoxConnection.new),
          proxmoxClientProvider.overrideWith((_) async => client),
        ],
      );
      await tester.tap(find.byIcon(CupertinoIcons.power));
      await frames(tester);
      await tester.pump(const Duration(milliseconds: 400));
      final old = tester
          .widgetList<CupertinoActionSheetAction>(
            find.byType(CupertinoActionSheetAction),
          )
          .firstWhere((button) => button.isDestructiveAction)
          .onPressed;
      await sleep(tester);
      expect(find.byType(CupertinoActionSheet), findsNothing);
      await wake(tester);
      old();
      await frames(tester);
      expect(client.writes, 0);
      expect(tester.takeException(), isNull);
      await h.close(tester);
    },
  );

  test('interaction epochs expire on each inactive transition only', () {
    final value = AppInteractionController();
    expect(value.epoch, 0);
    value.setActive(false);
    value.setActive(false);
    expect(value.epoch, 1);
    value.setActive(true);
    expect(value.epoch, 1);
    value.setActive(false);
    expect(value.epoch, 2);
    value.dispose();
  });

  testWidgets(
    'focused Enter wakes without firing the underlying command or repeat',
    (tester) async {
      final h = _Harness();
      final key = GlobalKey<_ProbeState>();
      await h.mount(tester, _Probe(key: key));
      expect(key.currentState!.focus.hasFocus, isTrue);
      await sleep(tester);
      expect(key.currentState!.focus.hasFocus, isFalse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await frames(tester);
      expect(clock, findsNothing);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      expect(key.currentState!.commands, 0);
      key.currentState!.focus.requestFocus();
      await frames(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(key.currentState!.commands, 1);
      await h.close(tester);
    },
  );

  testWidgets(
    'complete Ctrl wake chord is consumed before ancestor shortcuts',
    (tester) async {
      final h = _Harness();
      var opens = 0;
      await h.mount(
        tester,
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
                opens++,
          },
          child: const _Probe(),
        ),
      );
      await sleep(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await frames(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(opens, 0);
      await h.close(tester);
    },
  );

  for (final input in ['key', 'wheel', 'pan', 'drag']) {
    testWidgets(
      '$input activity resets the countdown; provider updates do not',
      (tester) async {
        final h = _Harness();
        await h.mount(tester, const _Probe());
        await tester.pump(const Duration(seconds: 50));
        switch (input) {
          case 'key':
            await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
          case 'wheel':
            tester.binding.handlePointerEvent(
              const PointerScrollEvent(
                position: Offset(100, 100),
                scrollDelta: Offset(0, 30),
              ),
            );
          case 'pan':
            tester.binding.handlePointerEvent(
              const PointerPanZoomStartEvent(
                pointer: 3,
                position: Offset(100, 100),
              ),
            );
            tester.binding.handlePointerEvent(
              const PointerPanZoomUpdateEvent(
                pointer: 3,
                position: Offset(100, 100),
                pan: Offset(10, 0),
              ),
            );
            tester.binding.handlePointerEvent(
              const PointerPanZoomEndEvent(
                pointer: 3,
                position: Offset(100, 100),
              ),
            );
          case 'drag':
            await tester.drag(find.text('Command'), const Offset(0, 20));
        }
        await tester.pump(const Duration(seconds: 50));
        expect(clock, findsNothing);
        h.entities.replace(const AsyncData({}));
        await frames(tester);
        await tester.pump(const Duration(seconds: 11));
        await frames(tester);
        expect(clock, findsOneWidget);
        await h.close(tester);
      },
    );
  }

  testWidgets(
    'clock hides underlying semantics and tickers; first tap does not click through',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final h = _Harness();
      final key = GlobalKey<_ProbeState>();
      await h.mount(tester, _Probe(key: key));
      expect(
        find.bySemanticsLabel(RegExp('underlying action')),
        findsOneWidget,
      );
      await sleep(tester);
      final ticks = key.currentState!.ticks;
      await tester.pump(const Duration(seconds: 10));
      expect(key.currentState!.ticks, ticks);
      expect(
        tester.semantics
            .simulatedAccessibilityTraversal()
            .map((node) => node.label)
            .join('\n'),
        isNot(contains('underlying action')),
      );
      expect(
        find.bySemanticsLabel(RegExp('Tap or press a key')),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(350, 450));
      await frames(tester);
      expect(key.currentState!.clicks, 0);
      await tester.tap(find.text('Command'));
      await frames(tester);
      expect(key.currentState!.clicks, 1);
      semantics.dispose();
      await h.close(tester);
    },
  );

  testWidgets('wake wheel and pan gestures never reach the covered page', (
    tester,
  ) async {
    final h = _Harness();
    final key = GlobalKey<_ProbeState>();
    await h.mount(tester, _Probe(key: key));
    await sleep(tester);
    tester.binding.handlePointerEvent(
      const PointerScrollEvent(
        position: Offset(100, 100),
        scrollDelta: Offset(0, 30),
      ),
    );
    await frames(tester);
    expect(key.currentState!.scrolls, 0);
    await sleep(tester);
    tester.binding.handlePointerEvent(
      const PointerPanZoomStartEvent(pointer: 4, position: Offset(100, 100)),
    );
    await frames(tester);
    tester.binding.handlePointerEvent(
      const PointerPanZoomEndEvent(pointer: 4, position: Offset(100, 100)),
    );
    expect(key.currentState!.pans, 0);
    await h.close(tester);
  });

  for (final source in [
    'entitiesLoading',
    'entitiesError',
    'configLoading',
    'configError',
  ]) {
    testWidgets('$source never shows retained old weather', (tester) async {
      final h = _Harness();
      await h.mount(tester, const SizedBox.expand());
      await sleep(tester);
      expect(find.text('23° · sunny'), findsOneWidget);
      if (source == 'entitiesLoading') {
        h.entities.replace(
          const AsyncLoading<Map<String, HaEntity>>().copyWithPrevious(
            h.entities.state,
          ),
        );
      }
      if (source == 'entitiesError') {
        h.entities.replace(
          AsyncError<Map<String, HaEntity>>(
            StateError('private'),
            StackTrace.current,
          ).copyWithPrevious(h.entities.state),
        );
      }
      if (source == 'configLoading') {
        h.connection.replace(
          const AsyncLoading<HaConnectionConfig?>().copyWithPrevious(
            h.connection.state,
          ),
        );
      }
      if (source == 'configError') {
        h.connection.replace(
          AsyncError<HaConnectionConfig?>(
            StateError('private'),
            StackTrace.current,
          ).copyWithPrevious(h.connection.state),
        );
      }
      await frames(tester);
      expect(find.text('23° · sunny'), findsNothing);
      expect(find.textContaining('private'), findsNothing);
      await h.close(tester);
    });
  }

  testWidgets(
    'background removes clock and timers; resume starts a new countdown',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, const _Probe());
      await sleep(tester);
      _pause(tester);
      tester.binding.scheduleForcedFrame();
      await tester.pump(const Duration(hours: 5));
      expect(clock, findsNothing);
      _resume(tester);
      await tester.pump(const Duration(seconds: 59));
      expect(clock, findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await frames(tester);
      expect(clock, findsOneWidget);
      await h.close(tester);
      await tester.pump(const Duration(hours: 5));
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(320, 640),
    const Size(600, 360),
    const Size(1200, 800),
  ]) {
    testWidgets('clock fits $size with large text and safe areas', (
      tester,
    ) async {
      final h = _Harness();
      await h.mount(tester, const SizedBox.expand(), size: size, scale: 2);
      await sleep(tester);
      expect(tester.takeException(), isNull);
      await h.close(tester);
    });
  }

  testWidgets(
    'native local audio remains playing across idle, wake and background',
    (tester) async {
      final h = _Harness();
      final audio = FakeLocalAudioBridge()..current = audioState();
      addTearDown(audio.events.close);
      await h.mount(
        tester,
        const LocalAudioScreen(),
        overrides: [localAudioBridgeProvider.overrideWithValue(audio)],
      );
      expect(find.text('Current station'), findsOneWidget);
      await sleep(tester);
      await wake(tester);
      _pause(tester);
      await frames(tester);
      expect(audio.commands, isEmpty);
      expect(audio.plays, isEmpty);
      expect(audio.current.isPlaying, isTrue);
      _resume(tester);
      await h.close(tester);
    },
  );
}
