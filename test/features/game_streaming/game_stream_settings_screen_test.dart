import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/game_streaming/data/android_game_stream_port.dart';
import 'package:larenor/features/game_streaming/data/android_game_stream_v2_port.dart';
import 'package:larenor/features/game_streaming/data/core_game_stream_api.dart';
import 'package:larenor/features/game_streaming/data/game_stream_client_controller.dart';
import 'package:larenor/features/game_streaming/data/game_stream_recovery_store.dart';
import 'package:larenor/features/game_streaming/domain/game_stream_session.dart';
import 'package:larenor/features/game_streaming/presentation/game_stream_settings_screen.dart';
import 'package:larenor/features/settings/presentation/settings_split_screen.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../server/server_admin_test_support.dart';

const _screenSessionId = '7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c';
const _screenHostId = '8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c';
const _screenAppId = '9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c';

final class _EmbeddedCapabilitiesPort implements GameStreamCapabilityPort {
  int calls = 0;

  @override
  Future<AndroidGameStreamCapabilities> capabilities() async {
    calls += 1;
    return const AndroidGameStreamCapabilities(
      available: true,
      engineRevision: 'moonlight-android-12.2-larenor-embed-v3',
      intents: {GameStreamIntent.stream},
      provider: 'moonlight',
    );
  }
}

final class _MemoryRecoveryBackend implements GameStreamRecoveryBackend {
  String? value;
  int reads = 0;
  int? blockRead;
  Completer<void>? blocked;

  @override
  Future<String?> read() async {
    reads += 1;
    if (blockRead == reads) {
      blocked = Completer<void>();
      await blocked!.future;
    }
    return value;
  }

  @override
  Future<void> write(String value) async => this.value = value;

  @override
  Future<void> delete() async => value = null;
}

http.Response _screenJson(Object? value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: const {'content-type': 'application/json'},
);

Map<String, Object> _screenQuality() => {
  'codec': 'h264',
  'codecId': '1' * 32,
  'codecRevision': 1,
  'displayId': 0,
  'displayRevision': 1,
  'networkId': '2' * 32,
  'networkRevision': 1,
  'policyId': '3' * 32,
  'policyRevision': 1,
  'widthPixels': 1280,
  'heightPixels': 720,
  'framesPerSecond': 60,
  'bitrateKbps': 10000,
  'frameQueueDepth': 2,
  'inputQueueDepth': 1,
  'secureSurface': true,
};

Map<String, Object?> _screenCoreSession({String state = 'unknown'}) => {
  'schemaVersion': 2,
  'id': _screenSessionId,
  'hostId': _screenHostId,
  'appId': _screenAppId,
  'revision': 1,
  'state': state,
  'expiresAt': 1800000000.0,
  'coreAuthority': {
    'accountRevision': 7,
    'hostRevision': 1,
    'pairingRevision': 1,
    'catalogRevision': 1,
    'appRevision': 1,
    'selectedQuality': _screenQuality(),
  },
  'selectedQuality': _screenQuality(),
  'clientAuthority': {
    'routeRevision': 1,
    'lifecycleRevision': 1,
    'displayRevision': 1,
    'networkRevision': 1,
    'policyRevision': 1,
  },
};

Map<String, Object?> _screenHosts() => {
  'schemaVersion': 2,
  'scope': {'schemaVersion': 1, 'coreId': 'a' * 32, 'homeId': 'b' * 32},
  'accountRevision': 7,
  'hosts': <Object>[],
};

final class _CapabilitiesPort implements GameStreamCapabilityPort {
  _CapabilitiesPort({this.pending});

  final Completer<AndroidGameStreamCapabilities>? pending;
  int calls = 0;

  @override
  Future<AndroidGameStreamCapabilities> capabilities() {
    calls += 1;
    final wait = pending;
    if (calls == 1 && wait != null) return wait.future;
    return Future.value(
      const AndroidGameStreamCapabilities(
        available: false,
        engineRevision: null,
        intents: {},
      ),
    );
  }
}

final class _FailingProviderPort
    implements GameStreamCapabilityPort, GameStreamProviderPort {
  @override
  Future<AndroidGameStreamCapabilities> capabilities() => Future.value(
    const AndroidGameStreamCapabilities(
      available: true,
      engineRevision: 'moonlight-1202',
      intents: {},
      provider: 'moonlight',
      handoffOnly: true,
      inputKinds: {'touch', 'gamepad'},
    ),
  );

  @override
  Future<AndroidGameStreamProviderLaunch> openProvider() =>
      Future.error(const GameStreamException('provider_launch_failed'));
}

final class _PendingProviderPort extends _FailingProviderPort {
  final launches = <Completer<AndroidGameStreamProviderLaunch>>[];

  @override
  Future<AndroidGameStreamProviderLaunch> openProvider() {
    final pending = Completer<AndroidGameStreamProviderLaunch>();
    launches.add(pending);
    return pending.future;
  }

  void complete(int index) => launches[index].complete(
    const AndroidGameStreamProviderLaunch(
      provider: 'moonlight',
      engineRevision: 'moonlight-1202',
      handoffOnly: true,
    ),
  );
}

Future<AppInteractionController> _mount(
  WidgetTester tester, {
  required Widget child,
  required String language,
  required double width,
  AppInteractionController? interaction,
  List<Override> overrides = const [],
  bool settle = true,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = interaction ?? AppInteractionController();
  if (interaction == null) addTearDown(controller.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: AppInteractionScope(
        controller: controller,
        child: CupertinoApp(
          theme: larenorTheme(brightness: Brightness.light),
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: child,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return controller;
}

Future<AdminFixture> _screenAccount() async {
  final fixture = AdminFixture(role: ServerRole.member);
  await fixture.account.initialize();
  expect(fixture.account.session?.context?.coreId, 'a' * 32);
  return fixture;
}

GameStreamClientFactory _screenClientFactory({
  required AdminFixture account,
  required _MemoryRecoveryBackend recovery,
  required List<LarenorServerApi> transports,
  bool unknownSession = false,
  void Function()? created,
}) {
  return ({
    required core,
    required native,
    required authority,
    required isCurrent,
    required isCoverageCurrent,
  }) {
    created?.call();
    final transport = LarenorServerApi(
      endpoint: account.account.session!.endpoint,
      client: MockClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/hosts')) {
          return _screenJson(_screenHosts());
        }
        if (unknownSession &&
            request.method == 'GET' &&
            request.url.path.endsWith('/sessions/$_screenSessionId')) {
          return _screenJson(_screenCoreSession());
        }
        fail(
          'unexpected screen Core request ${request.method} ${request.url.path}',
        );
      }),
    );
    transports.add(transport);
    return GameStreamClientController(
      core: CoreGameStreamApi(
        transport,
        account.account.session!,
        isCurrent: isCurrent,
      ),
      native: native,
      authority: authority,
      isCurrent: isCurrent,
      isCoverageCurrent: isCoverageCurrent,
      recoveryStore: GameStreamRecoveryStore(backend: recovery),
    );
  };
}

void main() {
  testWidgets('each recreated game screen owns a fresh stable authority id', (
    tester,
  ) async {
    await _mount(
      tester,
      language: 'en',
      width: 600,
      child: GameStreamSettingsScreen(
        key: const ValueKey('first-game-screen'),
        port: _CapabilitiesPort(),
      ),
    );
    final firstState =
        tester.state(find.byType(GameStreamSettingsScreen)) as dynamic;
    final first = firstState.clientInstanceIdForTesting as String;
    expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(firstState.clientInstanceIdForTesting, first);

    await _mount(
      tester,
      language: 'en',
      width: 600,
      child: GameStreamSettingsScreen(
        key: const ValueKey('second-game-screen'),
        port: _CapabilitiesPort(),
      ),
    );
    final secondState =
        tester.state(find.byType(GameStreamSettingsScreen)) as dynamic;
    final second = secondState.clientInstanceIdForTesting as String;
    expect(second, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(second, isNot(first));
  });

  testWidgets('exact pairing prompt alone survives the focus event chain', (
    tester,
  ) async {
    final guard = GameStreamForegroundCoverageGuard();
    final owner = Object();
    var coverage = AndroidGameStreamForegroundCoverage.pairingPrompt;
    await _mount(
      tester,
      language: 'en',
      width: 600,
      child: GameStreamSettingsScreen(
        port: _CapabilitiesPort(),
        gateCurrent: () => true,
        foregroundCoverageGuard: guard,
      ),
    );
    guard.attach(owner, () async => coverage);
    addTearDown(() => guard.detach(owner));
    final l10n = AppLocalizations.of(
      tester.element(find.byType(GameStreamSettingsScreen)),
    );
    expect(find.text(l10n.gameStreamingUnavailable), findsOneWidget);

    tester.binding.handleViewFocusChanged(
      ui.ViewFocusEvent(
        viewId: tester.view.viewId,
        state: ui.ViewFocusState.unfocused,
        direction: ui.ViewFocusDirection.forward,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n.gameStreamingUnavailable), findsOneWidget);

    coverage = AndroidGameStreamForegroundCoverage.unavailable;
    tester.binding.handleViewFocusChanged(
      ui.ViewFocusEvent(
        viewId: tester.view.viewId,
        state: ui.ViewFocusState.focused,
        direction: ui.ViewFocusDirection.backward,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n.gameStreamingUnavailable), findsOneWidget);

    tester.binding.handleViewFocusChanged(
      ui.ViewFocusEvent(
        viewId: tester.view.viewId,
        state: ui.ViewFocusState.unfocused,
        direction: ui.ViewFocusDirection.forward,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n.gameStreamingNotChecked), findsOneWidget);
  });

  testWidgets('owned Game transfer survives cover and retires on return', (
    tester,
  ) async {
    final guard = GameStreamForegroundCoverageGuard();
    final owner = Object();
    var coverage = AndroidGameStreamForegroundCoverage.game;
    await _mount(
      tester,
      language: 'en',
      width: 600,
      child: GameStreamSettingsScreen(
        port: _CapabilitiesPort(),
        gateCurrent: () => true,
        foregroundCoverageGuard: guard,
      ),
    );
    guard.attach(owner, () async => coverage);
    addTearDown(() => guard.detach(owner));
    final l10n = AppLocalizations.of(
      tester.element(find.byType(GameStreamSettingsScreen)),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(find.text(l10n.gameStreamingUnavailable), findsOneWidget);

    coverage = AndroidGameStreamForegroundCoverage.unavailable;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(l10n.gameStreamingNotChecked), findsOneWidget);
  });

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        'game streaming route is discoverable and accessible $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            final port = _CapabilitiesPort();
            await _mount(
              tester,
              language: language,
              width: width,
              child: SettingsSplitScreen(
                gameStreamPort: port,
                remoteGateCurrent: () => true,
              ),
            );
            final l10n = AppLocalizations.of(
              tester.element(find.byType(SettingsSplitScreen)),
            );
            final entry = find.text(l10n.gameStreamingTitle).first;
            await tester.ensureVisible(entry);
            final entryNode = tester.getSemantics(entry);
            expect(entryNode.flagsCollection.isButton, isTrue);
            expect(
              entryNode.getSemanticsData().hasAction(ui.SemanticsAction.tap),
              isTrue,
            );
            expect(entryNode.rect.height, greaterThanOrEqualTo(48));
            Focus.of(tester.element(entry)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();

            expect(find.byType(GameStreamSettingsScreen), findsOneWidget);
            expect(
              tester
                  .getSemantics(
                    find.byKey(const ValueKey('game-stream-engine-header')),
                  )
                  .flagsCollection
                  .isHeader,
              isTrue,
            );
            final status = find.byKey(const ValueKey('game-stream-status'));
            expect(
              tester.getSemantics(status).flagsCollection.isLiveRegion,
              isTrue,
            );
            expect(
              tester.getSemantics(status).label,
              contains(l10n.gameStreamingUnavailable),
            );
            final refresh = find.byKey(const ValueKey('game-stream-refresh'));
            expect(tester.getRect(refresh).height, greaterThanOrEqualTo(48));
            expect(
              tester.getSemantics(refresh).flagsCollection.isButton,
              isTrue,
            );
            final refreshLabel = find.descendant(
              of: refresh,
              matching: find.byType(Text),
            );
            Focus.of(tester.element(refreshLabel)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.space);
            await tester.pumpAndSettle();
            expect(port.calls, 2);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets('late capability callback cannot revive an expired route', (
    tester,
  ) async {
    final pending = Completer<AndroidGameStreamCapabilities>();
    final port = _CapabilitiesPort(pending: pending);
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    await _mount(
      tester,
      language: 'en',
      width: 1280,
      interaction: interaction,
      settle: false,
      child: GameStreamSettingsScreen(port: port, gateCurrent: () => true),
    );
    await tester.pump();
    expect(port.calls, 1);
    interaction.setActive(false);
    interaction.setActive(true);
    await tester.pump();
    pending.complete(
      const AndroidGameStreamCapabilities(
        available: true,
        engineRevision: 'fixture-1',
        intents: {GameStreamIntent.stream},
      ),
    );
    await tester.pump();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(GameStreamSettingsScreen)),
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('game-stream-status')))
          .label,
      contains(l10n.gameStreamingNotChecked),
    );
    expect(find.text(l10n.gameStreamingAvailable), findsNothing);
  });

  testWidgets('covering the route expires previously verified capability', (
    tester,
  ) async {
    final port = _CapabilitiesPort();
    await _mount(
      tester,
      language: 'en',
      width: 1280,
      child: GameStreamSettingsScreen(port: port, gateCurrent: () => true),
    );
    final screen = find.byType(GameStreamSettingsScreen);
    final l10n = AppLocalizations.of(tester.element(screen));
    final navigator = Navigator.of(tester.element(screen));
    expect(find.text(l10n.gameStreamingUnavailable), findsOneWidget);
    unawaited(
      navigator.push(
        CupertinoPageRoute<void>(builder: (_) => const SizedBox.expand()),
      ),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text(l10n.gameStreamingNotChecked), findsOneWidget);
    expect(port.calls, 1);
  });

  testWidgets(
    'provider launch failure stays separate from verified capability',
    (tester) async {
      await _mount(
        tester,
        language: 'en',
        width: 600,
        child: GameStreamSettingsScreen(
          port: _FailingProviderPort(),
          gateCurrent: () => true,
        ),
      );
      final screen = find.byType(GameStreamSettingsScreen);
      final l10n = AppLocalizations.of(tester.element(screen));
      expect(find.text(l10n.gameStreamingAvailable), findsNothing);
      expect(find.textContaining('Moonlight is installed'), findsOneWidget);
      expect(find.text(l10n.gameStreamingBoundaryBody), findsNothing);
      await tester.tap(find.byKey(const ValueKey('game-stream-open-provider')));
      await tester.pumpAndSettle();
      final error = find.byKey(const ValueKey('game-stream-provider-error'));
      expect(error, findsOneWidget);
      expect(tester.getSemantics(error).flagsCollection.isLiveRegion, isTrue);
      expect(
        tester.getSemantics(error).label,
        contains('Moonlight could not be opened'),
      );
      expect(find.text(l10n.gameStreamingAvailable), findsNothing);
      expect(find.textContaining('Moonlight is installed'), findsOneWidget);
      expect(find.text(l10n.gameStreamingError), findsNothing);
    },
  );

  testWidgets('external launch retirement does not lock the next visit', (
    tester,
  ) async {
    final port = _PendingProviderPort();
    await _mount(
      tester,
      language: 'en',
      width: 600,
      child: GameStreamSettingsScreen(port: port, gateCurrent: () => true),
    );
    final open = find.byKey(const ValueKey('game-stream-open-provider'));
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pump();
    expect(port.launches, hasLength(1));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    final refresh = find.byKey(const ValueKey('game-stream-refresh'));
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(scroll.position.minScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pump();
    expect(port.launches, hasLength(2));
    expect(find.text('Opening Moonlight…'), findsOneWidget);

    port.complete(0);
    await tester.pump();
    expect(find.text('Opening Moonlight…'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('game-stream-provider-error')),
      findsNothing,
    );
    port.complete(1);
    await tester.pumpAndSettle();
    expect(find.text('Open Moonlight'), findsOneWidget);
  });

  testWidgets(
    'retired gate cannot dispatch an external launch from an old tap',
    (tester) async {
      var current = true;
      final port = _PendingProviderPort();
      await _mount(
        tester,
        language: 'tr',
        width: 1280,
        child: GameStreamSettingsScreen(port: port, gateCurrent: () => current),
      );
      expect(find.textContaining('Moonlight kurulu'), findsOneWidget);
      final open = find.byKey(const ValueKey('game-stream-open-provider'));
      await tester.ensureVisible(open);
      current = false;
      // The already-rendered tap closure is still enabled until a rebuild.
      await tester.tap(open);
      await tester.pump();
      expect(port.launches, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cold recovered unknown session exposes local close without selected app',
    (tester) async {
      final account = await _screenAccount();
      addTearDown(account.account.dispose);
      final backend = _MemoryRecoveryBackend();
      await GameStreamRecoveryStore(backend: backend).writeAny(
        GameStreamStopCleanupRecovery(
          scope: GameStreamRecoveryScope(
            coreId: 'a' * 32,
            homeId: 'b' * 32,
            accountId: adminId,
            familyId: sessionFamilyId,
          ),
          accountRevision: 7,
          sessionId: _screenSessionId,
          sessionRevision: 1,
          commandId: '5' * 32,
          retireRequestKey: 'retire-cold-recovery',
          nativeRetired: true,
        ),
      );
      final transports = <LarenorServerApi>[];
      addTearDown(() {
        for (final transport in transports) {
          transport.close();
        }
      });

      await _mount(
        tester,
        language: 'en',
        width: 600,
        overrides: [
          serverAccountControllerProvider.overrideWithValue(account.account),
        ],
        child: GameStreamSettingsScreen(
          port: _EmbeddedCapabilitiesPort(),
          gateCurrent: () => true,
          coverageGateCurrent: () => true,
          gateAuthority: () => const GameStreamGateAuthority(
            pinRevision: 1,
            pinConfigured: true,
            pinUnlocked: true,
          ),
          clientFactory: _screenClientFactory(
            account: account,
            recovery: backend,
            transports: transports,
            unknownSession: true,
          ),
        ),
      );

      expect(find.byType(GameStreamSettingsScreen), findsOneWidget);
      final screenState =
          tester.state(find.byType(GameStreamSettingsScreen)) as dynamic;
      expect(
        (screenState.clientStateForTesting as GameStreamClientSnapshot?)?.phase,
        GameStreamClientPhase.outcomeUnknown,
      );
      expect(
        (screenState.clientStateForTesting as GameStreamClientSnapshot?)
            ?.activeSession,
        isNotNull,
      );
      final localClose = find.byKey(
        const ValueKey('game-stream-close-local-session'),
      );
      await tester.scrollUntilVisible(
        localClose,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(localClose, findsOneWidget);
      expect(find.byKey(const ValueKey('game-stream-start')), findsNothing);
      expect(find.byKey(const ValueKey('game-stream-stop')), findsNothing);
    },
  );

  testWidgets(
    'refresh waits exact prior controller cleanup and stays disabled meanwhile',
    (tester) async {
      final account = await _screenAccount();
      addTearDown(account.account.dispose);
      final backend = _MemoryRecoveryBackend()..blockRead = 2;
      final transports = <LarenorServerApi>[];
      addTearDown(() {
        for (final transport in transports) {
          transport.close();
        }
      });
      final port = _EmbeddedCapabilitiesPort();
      var created = 0;

      await _mount(
        tester,
        language: 'en',
        width: 600,
        overrides: [
          serverAccountControllerProvider.overrideWithValue(account.account),
        ],
        child: GameStreamSettingsScreen(
          port: port,
          gateCurrent: () => true,
          coverageGateCurrent: () => true,
          gateAuthority: () => const GameStreamGateAuthority(
            pinRevision: 1,
            pinConfigured: true,
            pinUnlocked: true,
          ),
          clientFactory: _screenClientFactory(
            account: account,
            recovery: backend,
            transports: transports,
            created: () => created += 1,
          ),
        ),
      );
      expect(created, 1);
      expect(port.calls, 1);

      final refresh = find.byKey(const ValueKey('game-stream-refresh'));
      await tester.ensureVisible(refresh);
      await tester.tap(refresh);
      await tester.pump();
      expect(backend.blocked, isNotNull);
      expect(created, 1);
      expect(port.calls, 2);
      expect(
        tester
            .getSemantics(refresh)
            .getSemanticsData()
            .hasAction(ui.SemanticsAction.tap),
        isFalse,
      );

      await tester.tap(refresh, warnIfMissed: false);
      await tester.pump();
      expect(created, 1);
      expect(port.calls, 2);

      backend.blocked!.complete();
      await tester.pumpAndSettle();
      expect(created, 2);
      expect(port.calls, 2);
    },
  );

  for (final language in ['en', 'tr']) {
    testWidgets(
      'unknown stream offers only exact local session close $language',
      (tester) async {
        var stopCalls = 0;
        var localCloseCalls = 0;
        await _mount(
          tester,
          language: language,
          width: 600,
          child: GameStreamSessionLifecycleAction(
            phase: GameStreamClientPhase.outcomeUnknown,
            hasActiveSession: true,
            enabled: true,
            onStop: () => stopCalls += 1,
            onCloseLocalSession: () => localCloseCalls += 1,
          ),
        );

        expect(
          find.byKey(const ValueKey('game-stream-close-local-session')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('game-stream-stop')), findsNothing);
        expect(
          find.textContaining(
            language == 'tr' ? 'yerel oturumu' : 'local session',
          ),
          findsWidgets,
        );

        await tester.tap(
          find.byKey(const ValueKey('game-stream-close-local-session')),
        );
        await tester.pump();
        expect(localCloseCalls, 1);
        expect(stopCalls, 0);
      },
    );
  }

  testWidgets('unknown non-session outcome does not offer local close', (
    tester,
  ) async {
    await _mount(
      tester,
      language: 'en',
      width: 600,
      child: GameStreamSessionLifecycleAction(
        phase: GameStreamClientPhase.outcomeUnknown,
        hasActiveSession: false,
        enabled: false,
        onStop: () {},
        onCloseLocalSession: () {},
      ),
    );
    expect(
      find.byKey(const ValueKey('game-stream-close-local-session')),
      findsNothing,
    );
  });
}
