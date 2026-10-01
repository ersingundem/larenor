// ignore_for_file: prefer_initializing_formals

import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/game_stream_session.dart';
import '../../server/domain/server_models.dart';
import 'android_game_stream_v2_port.dart';
import 'core_game_stream_api.dart';
import 'game_stream_recovery_store.dart';

enum GameStreamClientPhase {
  idle,
  loading,
  discovering,
  pairing,
  configuring,
  ready,
  dispatching,
  streaming,
  stopping,
  closing,
  revoking,
  outcomeUnknown,
  unavailable,
  error,
}

final class GameStreamClientSnapshot {
  const GameStreamClientSnapshot({
    this.phase = GameStreamClientPhase.idle,
    this.accountRevision,
    this.hosts = const [],
    this.candidates = const [],
    this.selectedHost,
    this.apps = const [],
    this.selectedApp,
    this.capabilities,
    this.selectedQuality,
    this.activeSession,
    this.lastCommand,
    this.errorCode,
  });

  final GameStreamClientPhase phase;
  final int? accountRevision;
  final List<CoreGameStreamHost> hosts;
  final List<AndroidGameStreamCandidate> candidates;
  final CoreGameStreamHost? selectedHost;
  final List<CoreGameStreamApp> apps;
  final CoreGameStreamApp? selectedApp;
  final AndroidGameStreamSessionCapabilities? capabilities;
  final AndroidGameStreamQualityOption? selectedQuality;
  final CoreGameStreamSession? activeSession;
  final CoreGameStreamCommand? lastCommand;
  final String? errorCode;

  bool get busy => {
    GameStreamClientPhase.loading,
    GameStreamClientPhase.discovering,
    GameStreamClientPhase.pairing,
    GameStreamClientPhase.configuring,
    GameStreamClientPhase.dispatching,
    GameStreamClientPhase.stopping,
    GameStreamClientPhase.closing,
    GameStreamClientPhase.revoking,
  }.contains(phase);

  GameStreamClientSnapshot copyWith({
    GameStreamClientPhase? phase,
    int? accountRevision,
    List<CoreGameStreamHost>? hosts,
    List<AndroidGameStreamCandidate>? candidates,
    CoreGameStreamHost? selectedHost,
    bool clearSelectedHost = false,
    List<CoreGameStreamApp>? apps,
    CoreGameStreamApp? selectedApp,
    bool clearSelectedApp = false,
    AndroidGameStreamSessionCapabilities? capabilities,
    bool clearCapabilities = false,
    AndroidGameStreamQualityOption? selectedQuality,
    bool clearSelectedQuality = false,
    CoreGameStreamSession? activeSession,
    bool clearActiveSession = false,
    CoreGameStreamCommand? lastCommand,
    bool clearLastCommand = false,
    String? errorCode,
    bool clearError = false,
  }) => GameStreamClientSnapshot(
    phase: phase ?? this.phase,
    accountRevision: accountRevision ?? this.accountRevision,
    hosts: hosts ?? this.hosts,
    candidates: candidates ?? this.candidates,
    selectedHost: clearSelectedHost ? null : selectedHost ?? this.selectedHost,
    apps: apps ?? this.apps,
    selectedApp: clearSelectedApp ? null : selectedApp ?? this.selectedApp,
    capabilities: clearCapabilities ? null : capabilities ?? this.capabilities,
    selectedQuality: clearSelectedQuality
        ? null
        : selectedQuality ?? this.selectedQuality,
    activeSession: clearActiveSession
        ? null
        : activeSession ?? this.activeSession,
    lastCommand: clearLastCommand ? null : lastCommand ?? this.lastCommand,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
  );
}

/// One route-scoped orchestration owner. It never creates provider facts and
/// never retries an operation after a dispatch grant has crossed to native.
final class GameStreamClientController extends ChangeNotifier {
  GameStreamClientController({
    required CoreGameStreamApi core,
    required GameStreamNativeV2Port native,
    required AndroidGameStreamAuthorityV2 Function(int accountRevision)
    authority,
    required bool Function() isCurrent,
    bool Function()? isCoverageCurrent,
    GameStreamRecoveryStore? recoveryStore,
    DateTime Function()? now,
    Random? random,
  }) : _core = core,
       _native = native,
       _authority = authority,
       _current = isCurrent,
       _coverageCurrent = isCoverageCurrent ?? isCurrent,
       _recoveryStore = recoveryStore ?? GameStreamRecoveryStore(),
       _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  final CoreGameStreamApi _core;
  final GameStreamNativeV2Port _native;
  final AndroidGameStreamAuthorityV2 Function(int accountRevision) _authority;
  final bool Function() _current;
  final bool Function() _coverageCurrent;
  final GameStreamRecoveryStore _recoveryStore;
  final DateTime Function() _now;
  final Random _random;

  GameStreamClientSnapshot _state = const GameStreamClientSnapshot();
  GameStreamClientSnapshot get state => _state;
  int _generation = 0;
  bool _disposed = false;
  CoreGameStreamPairingIntent? _pairingIntent;
  AndroidGameStreamDiscovery? _discovery;
  AndroidGameStreamResolvedBinding? _binding;
  AndroidGameStreamAuthorityV2? _pairingAuthority;
  String? _authorityRetirementId;
  String? _authorityRetirementBindingId;
  int? _authorityRetirementBindingRevision;
  AndroidGameStreamAuthorityV2? _foregroundAuthority;
  AndroidGameStreamResolvedBinding? _foregroundBinding;
  CoreGameStreamSession? _foregroundSession;

  Future<void> initialize() async {
    await refresh();
    if (_state.accountRevision != null &&
        _state.phase != GameStreamClientPhase.error) {
      await recoverPending();
    }
  }

  Future<void> refresh() async {
    final generation = _begin(GameStreamClientPhase.loading);
    try {
      final result = await _core.hosts();
      _assertCurrent(generation);
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.idle,
          accountRevision: result.accountRevision,
          hosts: result.hosts,
          candidates: const [],
          clearSelectedHost: true,
          apps: const [],
          clearSelectedApp: true,
          clearCapabilities: true,
          clearSelectedQuality: true,
          clearError: true,
        ),
      );
    } catch (error) {
      _fail(generation, error);
    }
  }

  /// Core creates the expiring intent before native discovery begins. A
  /// replayed Core response has no grant and therefore cannot reach native.
  Future<void> beginPairing() async {
    _assertEffectAvailable();
    final accountRevision = _state.accountRevision;
    if (accountRevision == null) {
      throw const GameStreamException('account_authority_missing');
    }
    final generation = _begin(GameStreamClientPhase.discovering);
    try {
      if (await _recoveryStore.readStored() != null) {
        throw const GameStreamException('operation_busy');
      }
      _assertCurrent(generation);
      final requestId = _id();
      final authority = _authority(accountRevision);
      final intent = await _core.createPairing(
        requestKey: 'pairing-$requestId',
        accountRevision: accountRevision,
        expiresAt: _now().toUtc().add(const Duration(minutes: 5)),
      );
      _assertCurrent(generation);
      if (intent.pairingGrant == null) {
        throw const GameStreamException('pairing_reconcile_required');
      }
      final recovery = GameStreamPairingRecovery(
        scope: _recoveryScope(authority),
        authority: authority,
        accountRevision: accountRevision,
        pairingId: intent.id,
        pairingRevision: intent.revision,
        pairingGrant: intent.pairingGrant!,
        expiresAtMillis: intent.expiresAt.millisecondsSinceEpoch,
      );
      _authorityRetirementId = intent.id;
      await _recoveryStore.writeAny(recovery);
      _assertCurrent(generation);
      _pairingIntent = intent;
      _pairingAuthority = authority;
      final discovery = await _native.beginPairing(
        requestId: requestId,
        authority: authority,
        timeoutMs: 15000,
      );
      _assertCurrent(generation);
      _discovery = discovery;
      _authorityRetirementBindingId = discovery.nativeBindingId;
      _authorityRetirementBindingRevision = discovery.bindingRevision;
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.idle,
          candidates: discovery.candidates,
          clearError: true,
        ),
      );
    } catch (error) {
      _fail(generation, error);
    }
  }

  Future<void> pair(AndroidGameStreamCandidate candidate) async {
    final accountRevision = _state.accountRevision;
    final intent = _pairingIntent;
    final discovery = _discovery;
    if (accountRevision == null || intent == null || discovery == null) {
      throw const GameStreamException('pairing_intent_missing');
    }
    if (!identical(
      discovery.candidates.firstWhere(
        (item) => item.id == candidate.id,
        orElse: () => throw const GameStreamException('stale_candidate'),
      ),
      candidate,
    )) {
      throw const GameStreamException('stale_candidate');
    }
    final generation = _begin(GameStreamClientPhase.pairing);
    try {
      final authority = _pairingAuthority ?? _authority(accountRevision);
      _pairingAuthority = authority;
      final stored = await _recoveryStore.readStored();
      if (stored is! GameStreamPairingRecovery ||
          stored.pairingId != intent.id ||
          stored.authorityRetirementPending) {
        throw const GameStreamException('pairing_recovery_missing');
      }
      final recovery = stored.withPairingDispatched();
      await _recoveryStore.writeAny(recovery);
      _assertCurrent(generation);
      AndroidGameStreamPairingReceipt? native;
      try {
        native = await _native.pair(
          requestId: _id(),
          authority: authority,
          discovery: discovery,
          intent: intent,
          candidate: candidate,
        );
      } catch (_) {
        _assertCurrent(generation);
        try {
          native = await _native.reconcilePairing(
            requestId: _id(),
            authority: authority,
            pairingId: intent.id,
          );
        } catch (_) {
          native = null;
        }
      }
      _assertCurrent(generation);
      if (native == null) {
        _pairingIntent = null;
        _discovery = null;
        _set(
          _state.copyWith(
            phase: GameStreamClientPhase.outcomeUnknown,
            candidates: const [],
            errorCode: 'pairing_outcome_unknown',
          ),
        );
        return;
      }
      final observation = native.observation;
      if (native.state != 'paired' || observation == null) {
        if (native.state == 'rejected') {
          final retired = await _retirePairingAuthority(
            recovery,
            discovery: discovery,
          );
          _assertCurrent(generation);
          await _recoveryStore.clearAny(retired);
          _pairingAuthority = null;
          _clearAuthorityRetirementLease();
        }
        _pairingIntent = null;
        _discovery = null;
        _set(
          _state.copyWith(
            phase: native.state == 'unknown'
                ? GameStreamClientPhase.outcomeUnknown
                : GameStreamClientPhase.error,
            candidates: const [],
            errorCode: native.state == 'unknown'
                ? 'pairing_outcome_unknown'
                : 'pairing_rejected',
          ),
        );
        return;
      }
      final registration = await _core.completePairing(intent, observation);
      _assertCurrent(generation);
      await _native.commitRegistration(
        requestId: _id(),
        authority: authority,
        discovery: discovery,
        registration: registration,
      );
      _assertCurrent(generation);
      await _recoveryStore.clearAny(recovery);
      _pairingIntent = null;
      _discovery = null;
      _pairingAuthority = null;
      _clearAuthorityRetirementLease();
      final hosts = await _core.hosts();
      _assertCurrent(generation);
      final registeredHost = _singleWhereOrNull(
        hosts.hosts,
        (item) => _hostEqual(item, registration.host),
      );
      if (registeredHost == null) {
        throw const GameStreamException('pairing_readback_mismatch');
      }
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.idle,
          accountRevision: hosts.accountRevision,
          hosts: hosts.hosts,
          candidates: const [],
          selectedHost: registeredHost,
          apps: registration.apps,
          clearSelectedApp: true,
          clearCapabilities: true,
          clearSelectedQuality: true,
          clearError: true,
        ),
      );
    } catch (error) {
      _fail(generation, error);
    }
  }

  Future<void> selectHost(CoreGameStreamHost host) async {
    if (!_sameHost(_state.hosts, host)) {
      throw const GameStreamException('stale_host');
    }
    final generation = _begin(GameStreamClientPhase.loading);
    try {
      final catalog = await _core.apps(host);
      _assertCurrent(generation);
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.ready,
          selectedHost: host,
          apps: catalog.apps,
          clearSelectedApp: true,
          clearCapabilities: true,
          clearSelectedQuality: true,
          clearError: true,
        ),
      );
    } catch (error) {
      _fail(generation, error);
    }
  }

  Future<void> refreshCatalog() async {
    _assertEffectAvailable();
    final host = _state.selectedHost;
    final accountRevision = _state.accountRevision;
    if (host == null || accountRevision == null) {
      throw const GameStreamException('catalog_authority_missing');
    }
    final generation = _begin(GameStreamClientPhase.loading);
    try {
      if (await _recoveryStore.readStored() != null) {
        throw const GameStreamException('operation_busy');
      }
      _assertCurrent(generation);
      final authority = _authority(accountRevision);
      final intent = await _core.createCatalogObservation(
        host,
        requestKey: 'catalog-${_id()}',
        accountRevision: accountRevision,
        expiresAt: _now().toUtc().add(const Duration(minutes: 2)),
      );
      _assertCurrent(generation);
      if (intent.catalogGrant == null) {
        _set(
          _state.copyWith(
            phase: GameStreamClientPhase.outcomeUnknown,
            errorCode: 'catalog_reconcile_required',
          ),
        );
        return;
      }
      var recovery = GameStreamCatalogRecovery(
        scope: _recoveryScope(authority),
        authority: authority,
        accountRevision: accountRevision,
        observationId: intent.id,
        observationRevision: intent.revision,
        catalogGrant: intent.catalogGrant!,
        expiresAtMillis: intent.expiresAt.millisecondsSinceEpoch,
        host: host,
      );
      _pairingAuthority = authority;
      _authorityRetirementId = intent.id;
      await _recoveryStore.writeAny(recovery);
      _assertCurrent(generation);
      final binding = await _native.resolveHostBinding(
        requestId: _id(),
        authority: authority,
        host: host,
      );
      _assertCurrent(generation);
      _authorityRetirementBindingId = binding.nativeBindingId;
      _authorityRetirementBindingRevision = binding.bindingRevision;
      recovery = recovery.withBinding(
        nativeBindingId: binding.nativeBindingId,
        bindingRevision: binding.bindingRevision,
        registrationRevision: binding.registrationRevision,
        engineRevision: binding.engineRevision,
      );
      await _recoveryStore.writeAny(recovery);
      _assertCurrent(generation);
      recovery = recovery.withCatalogDispatched();
      await _recoveryStore.writeAny(recovery);
      _assertCurrent(generation);
      AndroidGameStreamCatalogReceipt? native;
      try {
        native = await _native.readCatalog(
          requestId: _id(),
          authority: authority,
          binding: binding,
          host: host,
          intent: intent,
        );
      } catch (_) {
        _assertCurrent(generation);
        _set(
          _state.copyWith(
            phase: GameStreamClientPhase.outcomeUnknown,
            errorCode: 'catalog_outcome_unknown',
          ),
        );
        return;
      }
      _assertCurrent(generation);
      final observation = native.observation;
      if (native.state != 'observed' || observation == null) {
        _set(
          _state.copyWith(
            phase: GameStreamClientPhase.outcomeUnknown,
            errorCode: 'catalog_outcome_unknown',
          ),
        );
        return;
      }
      final update = await _core.completeCatalogObservation(
        host,
        intent,
        observation,
      );
      _assertCurrent(generation);
      await _native.commitCatalogRegistration(
        requestId: _id(),
        authority: authority,
        binding: binding,
        update: update,
      );
      _assertCurrent(generation);
      await _recoveryStore.clearAny(recovery);
      _pairingAuthority = null;
      _clearAuthorityRetirementLease();
      final hosts = await _core.hosts();
      _assertCurrent(generation);
      final refreshedHost = _singleWhereOrNull(
        hosts.hosts,
        (item) => item.id == host.id,
      );
      if (refreshedHost == null ||
          refreshedHost.revision != update.hostRevision ||
          refreshedHost.pairingRevision != update.pairingRevision ||
          refreshedHost.catalogRevision != update.catalogRevision) {
        throw const GameStreamException('catalog_readback_mismatch');
      }
      final catalog = await _core.apps(refreshedHost);
      _assertCurrent(generation);
      final previousAppId = _state.selectedApp?.id;
      final selectedApp = previousAppId == null
          ? null
          : _singleWhereOrNull(
              catalog.apps,
              (item) => item.id == previousAppId,
            );
      _binding = null;
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.ready,
          accountRevision: hosts.accountRevision,
          hosts: hosts.hosts,
          selectedHost: refreshedHost,
          apps: catalog.apps,
          selectedApp: selectedApp,
          clearSelectedApp: selectedApp == null,
          clearCapabilities: true,
          clearSelectedQuality: true,
          clearActiveSession: true,
          clearLastCommand: true,
          clearError: true,
        ),
      );
    } catch (error) {
      _fail(generation, error);
    }
  }

  Future<void> configurePolicy(AndroidGameStreamPolicyDraft policy) async {
    _assertEffectAvailable();
    final accountRevision = _state.accountRevision;
    if (accountRevision == null) {
      throw const GameStreamException('account_authority_missing');
    }
    final generation = _begin(GameStreamClientPhase.configuring);
    try {
      final authority = _authority(accountRevision);
      _requirePin(authority, policy.requirePin);
      await _native.configurePolicy(
        requestId: _id(),
        authority: authority,
        expectedPolicyRevision: _state.capabilities?.policy?.revision ?? 0,
        policy: policy,
      );
      _assertCurrent(generation);
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.ready,
          clearCapabilities: true,
          clearSelectedQuality: true,
          clearError: true,
        ),
      );
    } catch (error) {
      _fail(generation, error);
    }
  }

  Future<void> selectApp(CoreGameStreamApp app) async {
    final host = _state.selectedHost;
    final accountRevision = _state.accountRevision;
    if (host == null ||
        accountRevision == null ||
        app.hostId != host.id ||
        !_sameApp(_state.apps, app)) {
      throw const GameStreamException('stale_app');
    }
    final generation = _begin(GameStreamClientPhase.loading);
    try {
      final authority = _authority(accountRevision);
      final binding = await _native.resolveBinding(
        requestId: _id(),
        authority: authority,
        host: host,
        app: app,
      );
      _assertCurrent(generation);
      final capabilities = await _native.sessionCapabilities(
        requestId: _id(),
        authority: authority,
        host: host,
        app: app,
      );
      _assertCurrent(generation);
      _binding = binding;
      _set(
        _state.copyWith(
          phase: capabilities.available
              ? GameStreamClientPhase.ready
              : GameStreamClientPhase.unavailable,
          selectedApp: app,
          capabilities: capabilities,
          selectedQuality: capabilities.qualityOptions.isEmpty
              ? null
              : capabilities.qualityOptions.first,
          clearSelectedQuality: capabilities.qualityOptions.isEmpty,
          errorCode: capabilities.available ? null : capabilities.reason,
          clearError: capabilities.available,
        ),
      );
    } catch (error) {
      _binding = null;
      _fail(generation, error);
    }
  }

  void chooseQuality(AndroidGameStreamQualityOption option) {
    final capabilities = _state.capabilities;
    if (capabilities == null ||
        !capabilities.available ||
        !capabilities.qualityOptions.contains(option)) {
      throw const GameStreamException('invalid_quality_option');
    }
    _set(_state.copyWith(selectedQuality: option, clearError: true));
  }

  Future<void> start() => _dispatchStart();

  Future<void> stop() {
    _assertEffectAvailable();
    return _dispatchStop();
  }

  Future<void> _dispatchStart() async {
    _assertEffectAvailable();
    final host = _state.selectedHost;
    final app = _state.selectedApp;
    final accountRevision = _state.accountRevision;
    final selected = _state.selectedQuality;
    final binding = _binding;
    if (host == null ||
        app == null ||
        accountRevision == null ||
        selected == null ||
        binding == null) {
      throw const GameStreamException('session_not_ready');
    }
    final generation = _begin(GameStreamClientPhase.dispatching);
    GameStreamSessionBindRecovery? pendingBind;
    CoreGameStreamSession? openedSession;
    var bound = false;
    try {
      final authority = _authority(accountRevision);
      _requirePin(authority, _state.capabilities?.policy?.requirePin == true);
      final latestHosts = await _core.hosts();
      _assertCurrent(generation);
      final latestHost = _singleWhereOrNull(
        latestHosts.hosts,
        (item) => item.id == host.id,
      );
      if (latestHost == null || !_hostEqual(latestHost, host)) {
        throw const GameStreamException('stale_host');
      }
      final latestCatalog = await _core.apps(latestHost);
      _assertCurrent(generation);
      final latestApp = _singleWhereOrNull(
        latestCatalog.apps,
        (item) => item.id == app.id,
      );
      if (latestApp == null || !_appEqual(latestApp, app)) {
        throw const GameStreamException('stale_app');
      }
      final latestCapabilities = await _native.sessionCapabilities(
        requestId: _id(),
        authority: authority,
        host: latestHost,
        app: latestApp,
      );
      _assertCurrent(generation);
      final matchingQuality = _singleWhereOrNull(
        latestCapabilities.qualityOptions,
        (item) => _qualityEqual(item, selected),
      );
      if (!latestCapabilities.available || matchingQuality == null) {
        throw const GameStreamException('stale_quality');
      }
      final currentAuthority = _authority(accountRevision);
      _requirePin(
        currentAuthority,
        latestCapabilities.policy?.requirePin == true,
      );
      final coreAuthority = latestCapabilities.coreAuthority(
        routeRevision: currentAuthority.routeRevision,
        lifecycleRevision: currentAuthority.lifecycleRevision,
      );
      final exactQuality = latestCapabilities.selectedQuality(matchingQuality);
      final session = await _core.open(
        host: latestHost,
        app: latestApp,
        accountRevision: latestHosts.accountRevision,
        clientAuthority: coreAuthority,
        selectedQuality: exactQuality,
        requestKey: 'session-${_id()}',
        expiresAt: _now().toUtc().add(
          Duration(seconds: latestCapabilities.policy!.maximumSessionSeconds),
        ),
      );
      openedSession = session;
      _assertCurrent(generation);
      pendingBind = GameStreamSessionBindRecovery(
        scope: _recoveryScope(currentAuthority),
        accountRevision: accountRevision,
        sessionId: session.id,
        sessionRevision: session.revision,
        retireRequestKey: 'retire-bind-${_id()}',
      );
      await _recoveryStore.writeAny(pendingBind);
      _assertCurrent(generation);
      await _native.bindSession(
        authority: currentAuthority,
        binding: binding,
        session: session,
        selectedQuality: exactQuality,
      );
      _assertCurrent(generation);
      _foregroundAuthority = currentAuthority;
      _foregroundBinding = binding;
      _foregroundSession = session;
      _set(_state.copyWith(activeSession: session));
      bound = true;
      final cleanup = pendingBind;
      pendingBind = null;
      final launched = await _dispatchBoundStartCommand(
        generation: generation,
        authority: currentAuthority,
        session: session,
        cleanup: cleanup,
        intent: 'launch',
        expectedResult: 'appRunning',
        expectedObservationKind: 'currentGameMatched',
        terminalPhase: GameStreamClientPhase.dispatching,
      );
      if (!launched) return;
      await _dispatchBoundStartCommand(
        generation: generation,
        authority: currentAuthority,
        session: session,
        cleanup: cleanup,
        intent: 'stream',
        expectedResult: 'streaming',
        expectedObservationKind: 'connectionStarted',
        terminalPhase: GameStreamClientPhase.streaming,
        finalStage: true,
      );
    } catch (error) {
      if (!bound && pendingBind != null && openedSession != null) {
        final cleaned = await _retirePendingBind(pendingBind, openedSession);
        if (!cleaned && !_disposed && generation == _generation) {
          _set(
            _state.copyWith(
              phase: GameStreamClientPhase.outcomeUnknown,
              activeSession: openedSession,
              errorCode: 'session_bind_cleanup_unknown',
            ),
          );
          return;
        }
      }
      if (bound && !_disposed && generation == _generation) {
        _set(
          _state.copyWith(
            phase: GameStreamClientPhase.outcomeUnknown,
            activeSession: openedSession,
            errorCode: 'command_outcome_unknown',
          ),
        );
        return;
      }
      _fail(generation, error);
    }
  }

  Future<bool> _dispatchBoundStartCommand({
    required int generation,
    required AndroidGameStreamAuthorityV2 authority,
    required CoreGameStreamSession session,
    required GameStreamSessionBindRecovery cleanup,
    required String intent,
    required String expectedResult,
    required String expectedObservationKind,
    required GameStreamClientPhase terminalPhase,
    bool finalStage = false,
  }) async {
    _assertStartAuthorityCurrent(generation, authority);
    final authorization = await _core.authorize(
      session,
      requestKey: '$intent-${_id()}',
      intent: intent,
    );
    if (authorization.dispatchGrant == null) {
      _assertStartAuthorityCurrent(generation, authority);
      final current = await _core.readCommand(
        session,
        authorization.command.id,
      );
      _assertStartAuthorityCurrent(generation, authority);
      if (!_exactObservedCommand(
        current,
        commandId: authorization.command.id,
        intent: intent,
        result: expectedResult,
        observationKind: expectedObservationKind,
      )) {
        _set(
          _state.copyWith(
            phase: GameStreamClientPhase.outcomeUnknown,
            activeSession: session,
            lastCommand: current,
            errorCode: 'command_reconcile_required',
          ),
        );
        return false;
      }
      if (finalStage) await _recoveryStore.clearAny(cleanup);
      _assertStartAuthorityCurrent(generation, authority);
      _set(
        _state.copyWith(
          phase: terminalPhase,
          activeSession: session,
          lastCommand: current,
          clearError: true,
        ),
      );
      return true;
    }
    final recovery = GameStreamRecoveryRecord(
      scope: _recoveryScope(authority),
      sessionId: session.id,
      sessionRevision: session.revision,
      commandId: authorization.command.id,
      intent: authorization.command.intent,
      dispatchGrant: authorization.dispatchGrant!,
    );
    await _recoveryStore.write(recovery);
    _assertStartAuthorityCurrent(generation, authority);
    AndroidGameStreamCommandReceiptV2 native;
    try {
      native = await _native.executeV2(
        requestId: _id(),
        authority: authority,
        session: session,
        authorization: authorization,
      );
    } catch (_) {
      _assertStartAuthorityCurrent(generation, authority);
      CoreGameStreamCommand? terminal;
      try {
        final candidate = await _core.complete(
          session,
          authorization,
          state: 'unknown',
          result: 'unknown',
          observationKind: 'unknown',
        );
        _assertStartAuthorityCurrent(generation, authority);
        if (candidate.id != authorization.command.id ||
            candidate.intent != intent) {
          throw const GameStreamException('invalid_command_receipt');
        }
        terminal = candidate;
        await _recoveryStore.writeAny(cleanup);
      } catch (_) {
        // Keep the encrypted one-use grant when Core completion is uncertain.
        // Restart reconciliation never invokes the native effect again.
      }
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.outcomeUnknown,
          activeSession: session,
          lastCommand: terminal ?? authorization.command,
          errorCode: 'command_outcome_unknown',
        ),
      );
      return false;
    }
    _assertStartAuthorityCurrent(generation, authority);
    CoreGameStreamCommand completed;
    try {
      completed = await _core.complete(
        session,
        authorization,
        state: native.state,
        result: native.result,
        observationKind: native.observationKind,
        readbackRevision: native.readbackRevision,
        nativeReceiptDigest: native.nativeReceiptDigest,
      );
      _assertStartAuthorityCurrent(generation, authority);
      if (completed.id != authorization.command.id ||
          completed.intent != intent) {
        throw const GameStreamException('invalid_command_receipt');
      }
      final observed = _exactObservedCommand(
        completed,
        commandId: authorization.command.id,
        intent: intent,
        result: expectedResult,
        observationKind: expectedObservationKind,
      );
      if (!observed || !finalStage) {
        await _recoveryStore.writeAny(cleanup);
      } else {
        await _recoveryStore.clearExact(recovery);
      }
      _assertStartAuthorityCurrent(generation, authority);
      _set(
        _state.copyWith(
          phase: observed
              ? terminalPhase
              : GameStreamClientPhase.outcomeUnknown,
          activeSession: session,
          lastCommand: completed,
          errorCode: observed ? null : 'command_outcome_unknown',
          clearError: observed,
        ),
      );
      return observed;
    } catch (_) {
      _assertStartAuthorityCurrent(generation, authority);
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.outcomeUnknown,
          activeSession: session,
          lastCommand: authorization.command,
          errorCode: 'core_completion_unknown',
        ),
      );
      return false;
    }
  }

  void _assertStartAuthorityCurrent(
    int generation,
    AndroidGameStreamAuthorityV2 captured,
  ) {
    _assertCurrent(generation);
    final current = _authority(captured.accountRevision);
    if (!mapEquals(current.toJson(), captured.toJson())) {
      throw const GameStreamException('stale_client_authority');
    }
  }

  Future<void> _dispatchStop() async {
    final authority = _foregroundAuthority;
    final binding = _foregroundBinding;
    final leaseSession = _foregroundSession;
    if (authority == null || binding == null || leaseSession == null) {
      throw const GameStreamException('session_missing');
    }
    final generation = _begin(GameStreamClientPhase.stopping);
    try {
      final session = await _core.readSession(leaseSession.id);
      _assertCurrent(generation);
      if (session.state != 'open' ||
          session.revision != leaseSession.revision ||
          session.hostId != leaseSession.hostId ||
          session.appId != leaseSession.appId) {
        Object? nativeFailure;
        try {
          await _native.retireV2(
            sessionId: leaseSession.id,
            epoch: leaseSession.revision,
          );
        } catch (error) {
          nativeFailure = error;
        }
        try {
          await _core.retireSession(
            session,
            requestKey: 'retire-stale-${_id()}',
          );
        } catch (_) {}
        _assertCurrent(generation);
        _foregroundAuthority = null;
        _foregroundBinding = null;
        _foregroundSession = null;
        _set(
          _state.copyWith(
            phase: GameStreamClientPhase.outcomeUnknown,
            activeSession: session,
            errorCode: nativeFailure == null
                ? 'stop_session_retired'
                : 'native_retirement_unknown',
          ),
        );
        return;
      }
      final authorization = await _core.authorize(
        session,
        requestKey: 'stop-${_id()}',
        intent: 'stop',
      );
      _assertCurrent(generation);
      if (authorization.dispatchGrant == null) {
        final current = await _core.readCommand(
          session,
          authorization.command.id,
        );
        _assertCurrent(generation);
        _set(
          _state.copyWith(
            phase: current.state == 'native_observed'
                ? GameStreamClientPhase.ready
                : GameStreamClientPhase.outcomeUnknown,
            activeSession: session,
            lastCommand: current,
            errorCode: current.state == 'native_observed'
                ? null
                : 'command_reconcile_required',
            clearError: current.state == 'native_observed',
          ),
        );
        return;
      }
      final recovery = GameStreamRecoveryRecord(
        scope: _recoveryScope(authority),
        sessionId: session.id,
        sessionRevision: session.revision,
        commandId: authorization.command.id,
        intent: authorization.command.intent,
        dispatchGrant: authorization.dispatchGrant!,
      );
      await _recoveryStore.write(recovery);
      _assertCurrent(generation);
      AndroidGameStreamCommandReceiptV2 native;
      try {
        native = await _native.executeV2(
          requestId: _id(),
          authority: authority,
          session: leaseSession,
          authorization: authorization,
          safetyClosure: binding,
        );
      } catch (_) {
        _assertCurrent(generation);
        CoreGameStreamCommand? terminal;
        try {
          terminal = await _core.complete(
            session,
            authorization,
            state: 'unknown',
            result: 'unknown',
            observationKind: 'unknown',
          );
          _assertCurrent(generation);
          await _recoveryStore.clearExact(recovery);
        } catch (_) {}
        _set(
          _state.copyWith(
            phase: GameStreamClientPhase.outcomeUnknown,
            activeSession: session,
            lastCommand: terminal ?? authorization.command,
            errorCode: 'command_outcome_unknown',
          ),
        );
        return;
      }
      _assertCurrent(generation);
      CoreGameStreamCommand completed;
      try {
        completed = await _core.complete(
          session,
          authorization,
          state: native.state,
          result: native.result,
          observationKind: native.observationKind,
          readbackRevision: native.readbackRevision,
          nativeReceiptDigest: native.nativeReceiptDigest,
        );
        _assertCurrent(generation);
      } catch (_) {
        _assertCurrent(generation);
        _set(
          _state.copyWith(
            phase: GameStreamClientPhase.outcomeUnknown,
            activeSession: session,
            lastCommand: authorization.command,
            errorCode: 'core_completion_unknown',
          ),
        );
        return;
      }
      final observed = completed.state == 'native_observed';
      if (observed) {
        final cleanup = GameStreamStopCleanupRecovery(
          scope: _recoveryScope(authority),
          accountRevision: authority.accountRevision,
          sessionId: leaseSession.id,
          sessionRevision: leaseSession.revision,
          commandId: completed.id,
          retireRequestKey: 'retire-stop-${_id()}',
        );
        await _recoveryStore.writeAny(cleanup);
        _assertCurrent(generation);
        final cleaned = await _retireStopCleanup(cleanup, session);
        _assertCurrent(generation);
        if (cleaned) {
          _foregroundAuthority = null;
          _foregroundBinding = null;
          _foregroundSession = null;
        }
        _set(
          _state.copyWith(
            phase: cleaned
                ? GameStreamClientPhase.ready
                : GameStreamClientPhase.outcomeUnknown,
            activeSession: cleaned ? null : session,
            clearActiveSession: cleaned,
            lastCommand: completed,
            errorCode: cleaned ? null : 'stop_cleanup_unknown',
            clearError: cleaned,
          ),
        );
        return;
      }
      await _recoveryStore.clearExact(recovery);
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.outcomeUnknown,
          activeSession: session,
          lastCommand: completed,
          errorCode: 'command_outcome_unknown',
        ),
      );
    } catch (error) {
      _fail(generation, error);
    }
  }

  Future<bool> _retirePendingBind(
    GameStreamSessionBindRecovery record,
    CoreGameStreamSession session, {
    bool nativeAlreadyRetired = false,
  }) async {
    var currentRecord = record;
    var nativeRetired = record.nativeRetired || nativeAlreadyRetired;
    if (!nativeRetired) {
      try {
        await _native.retireV2(
          sessionId: record.sessionId,
          epoch: record.sessionRevision,
        );
        nativeRetired = true;
      } catch (_) {
        // The bind callback may have been lost after native accepted it.
        // Continue Core cleanup, but retain recovery until native returns the
        // exact retirement receipt; a generic channel failure proves nothing.
      }
    }
    if (nativeRetired && !currentRecord.nativeRetired) {
      try {
        currentRecord = currentRecord.withNativeRetired();
        await _recoveryStore.writeAny(currentRecord);
      } catch (_) {
        // The native fence is real, but without a durable phase transition a
        // restart cannot safely skip native cleanup. Do not claim completion.
        return false;
      }
    }
    try {
      final retired = await _core.retireSession(
        session,
        requestKey: currentRecord.retireRequestKey,
      );
      if (retired.id != currentRecord.sessionId || retired.state != 'retired') {
        return false;
      }
      if (!nativeRetired) return false;
      await _recoveryStore.clearAny(currentRecord);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _retireStopCleanup(
    GameStreamStopCleanupRecovery record,
    CoreGameStreamSession session,
  ) async {
    var currentRecord = record;
    var nativeRetired = record.nativeRetired;
    if (!nativeRetired) {
      try {
        await _native.retireV2(
          sessionId: record.sessionId,
          epoch: record.sessionRevision,
        );
        nativeRetired = true;
      } catch (_) {
        // The causal stop receipt remains true, but local ownership cleanup is
        // still unknown. Core retirement must run and the record must remain.
      }
    }
    if (nativeRetired && !currentRecord.nativeRetired) {
      try {
        currentRecord = currentRecord.withNativeRetired();
        await _recoveryStore.writeAny(currentRecord);
      } catch (_) {
        return false;
      }
    }
    var coreRetired = false;
    try {
      final retired = await _core.retireSession(
        session,
        requestKey: currentRecord.retireRequestKey,
      );
      coreRetired =
          retired.id == currentRecord.sessionId && retired.state == 'retired';
    } catch (_) {}
    if (!nativeRetired || !coreRetired) return false;
    await _recoveryStore.clearAny(currentRecord);
    return true;
  }

  Future<void> recoverPending() async {
    final accountRevision = _state.accountRevision;
    if (accountRevision == null) return;
    final authority = _authority(accountRevision);
    final scope = _recoveryScope(authority);
    final pending = await _recoveryStore.readStored();
    if (pending == null) return;
    final generation = _begin(GameStreamClientPhase.loading);
    try {
      if (!pending.scope.same(scope)) {
        await _fenceForeignScopeRecovery(pending, generation);
        return;
      }
      if (pending is! GameStreamRecoveryRecord) {
        await _recoverEffect(pending, authority, generation);
        return;
      }
      final record = pending;
      final session = await _core.readSession(record.sessionId);
      _assertCurrent(generation);
      if (record.nativeRetired) {
        var retired = session;
        if (session.state != 'retired') {
          if (session.state != 'open' ||
              session.revision != record.sessionRevision) {
            _set(
              _state.copyWith(
                phase: GameStreamClientPhase.outcomeUnknown,
                activeSession: session,
                errorCode: 'session_cleanup_unknown',
              ),
            );
            return;
          }
          retired = await _core.retireSession(
            session,
            requestKey: 'retire-command-${record.commandId}',
          );
          _assertCurrent(generation);
        }
        if (retired.state == 'retired') {
          await _recoveryStore.clearExact(record);
          _set(
            _state.copyWith(
              phase: GameStreamClientPhase.idle,
              clearActiveSession: true,
              clearError: true,
            ),
          );
        }
        return;
      }
      if (session.revision != record.sessionRevision ||
          session.state != 'open') {
        var nativeRetired = false;
        GameStreamSessionBindRecovery? retirement;
        try {
          await _native.retireV2(
            sessionId: record.sessionId,
            epoch: record.sessionRevision,
          );
          nativeRetired = true;
          retirement = GameStreamSessionBindRecovery(
            scope: record.scope,
            accountRevision: authority.accountRevision,
            sessionId: record.sessionId,
            sessionRevision: record.sessionRevision,
            retireRequestKey: 'retire-recovered-${_id()}',
            nativeRetired: true,
          );
          await _recoveryStore.writeAny(retirement);
        } catch (_) {
          // Core retirement or revision drift does not prove that a native
          // lease/effect for the original revision is gone. Preserve the
          // encrypted record for another exact retirement attempt.
          nativeRetired = false;
          retirement = null;
        }
        _assertCurrent(generation);
        if (nativeRetired) await _recoveryStore.clearAny(retirement!);
        _set(
          _state.copyWith(
            phase: GameStreamClientPhase.outcomeUnknown,
            activeSession: session,
            errorCode: nativeRetired
                ? 'recovered_session_retired'
                : 'native_retirement_unknown',
          ),
        );
        return;
      }
      final command = await _core.readCommand(session, record.commandId);
      _assertCurrent(generation);
      if (command.intent != record.intent || command.state != 'authorized') {
        if (command.intent == 'stop' &&
            command.state == 'native_observed' &&
            command.result == 'stopped') {
          final cleanup = GameStreamStopCleanupRecovery(
            scope: record.scope,
            accountRevision: authority.accountRevision,
            sessionId: record.sessionId,
            sessionRevision: record.sessionRevision,
            commandId: record.commandId,
            retireRequestKey: 'retire-stop-${_id()}',
          );
          await _recoveryStore.writeAny(cleanup);
          _assertCurrent(generation);
          final cleaned = await _retireStopCleanup(cleanup, session);
          _assertCurrent(generation);
          _set(
            _state.copyWith(
              phase: cleaned
                  ? GameStreamClientPhase.idle
                  : GameStreamClientPhase.outcomeUnknown,
              activeSession: cleaned ? null : session,
              clearActiveSession: cleaned,
              lastCommand: command,
              errorCode: cleaned ? null : 'stop_cleanup_unknown',
              clearError: cleaned,
            ),
          );
          return;
        }
        await _recoveryStore.clearExact(record);
        _set(
          _state.copyWith(
            phase:
                command.state == 'native_observed' &&
                    command.result == 'streaming'
                ? GameStreamClientPhase.streaming
                : command.state == 'native_observed'
                ? GameStreamClientPhase.ready
                : GameStreamClientPhase.outcomeUnknown,
            activeSession: session,
            lastCommand: command,
            errorCode: command.state == 'native_observed'
                ? null
                : 'recovered_terminal_unknown',
            clearError: command.state == 'native_observed',
          ),
        );
        return;
      }
      final native = await _native.reconcileCommand(
        requestId: _id(),
        authority: authority,
        commandId: record.commandId,
      );
      _assertCurrent(generation);
      if (native == null) {
        _set(
          _state.copyWith(
            phase: GameStreamClientPhase.outcomeUnknown,
            activeSession: session,
            lastCommand: command,
            errorCode: 'native_reconcile_pending',
          ),
        );
        return;
      }
      final authorization = CoreGameStreamAuthorization(
        command: command,
        dispatchGrant: record.dispatchGrant,
      );
      final completed = await _core.complete(
        session,
        authorization,
        state: native.state,
        result: native.result,
        observationKind: native.observationKind,
        readbackRevision: native.readbackRevision,
        nativeReceiptDigest: native.nativeReceiptDigest,
      );
      _assertCurrent(generation);
      await _recoveryStore.clearExact(record);
      _set(
        _state.copyWith(
          phase:
              completed.state == 'native_observed' &&
                  completed.result == 'streaming'
              ? GameStreamClientPhase.streaming
              : completed.state == 'native_observed'
              ? GameStreamClientPhase.ready
              : GameStreamClientPhase.outcomeUnknown,
          activeSession: session,
          lastCommand: completed,
          errorCode: completed.state == 'native_observed'
              ? null
              : 'recovered_terminal_unknown',
          clearError: completed.state == 'native_observed',
        ),
      );
    } catch (_) {
      if (!_disposed && generation == _generation) {
        _set(
          _state.copyWith(
            phase: GameStreamClientPhase.outcomeUnknown,
            errorCode: 'recovery_outcome_unknown',
          ),
        );
      }
    }
  }

  Future<void> _fenceForeignScopeRecovery(
    GameStreamPendingOperation pending,
    int generation,
  ) async {
    GameStreamPendingOperation current = pending;
    try {
      switch (pending) {
        case GameStreamRecoveryRecord():
          if (!pending.nativeRetired) {
            await _native.retireV2(
              sessionId: pending.sessionId,
              epoch: pending.sessionRevision,
            );
            current = pending.withNativeRetired();
            await _recoveryStore.writeAny(current);
          }
        case GameStreamSessionBindRecovery():
          if (!pending.nativeRetired) {
            await _native.retireV2(
              sessionId: pending.sessionId,
              epoch: pending.sessionRevision,
            );
            current = pending.withNativeRetired();
            await _recoveryStore.writeAny(current);
          }
        case GameStreamStopCleanupRecovery():
          if (!pending.nativeRetired) {
            await _native.retireV2(
              sessionId: pending.sessionId,
              epoch: pending.sessionRevision,
            );
            current = pending.withNativeRetired();
            await _recoveryStore.writeAny(current);
          }
        case GameStreamPairingRecovery():
          current = await _retirePairingAuthority(pending);
        case GameStreamCatalogRecovery():
          current = await _retireCatalogAuthority(pending);
        default:
          // Revocation evidence has no active local authority to fence. Keep
          // it intact for the original scope and never re-dispatch it.
          break;
      }
    } catch (_) {
      // The original authenticated Core scope is unavailable. Retain the
      // record even if the local exact fence is also temporarily unavailable.
    }
    _assertCurrent(generation);
    _set(
      _state.copyWith(
        phase: GameStreamClientPhase.outcomeUnknown,
        errorCode:
            current is GameStreamPairingRecovery && current.authorityRetired ||
                current is GameStreamCatalogRecovery &&
                    current.authorityRetired ||
                current != pending
            ? 'native_fenced_original_scope_required'
            : 'recovery_scope_changed',
      ),
    );
  }

  Future<AndroidGameStreamForegroundCoverage> foregroundCoverage() async {
    if (_disposed || !_coverageCurrent()) {
      return AndroidGameStreamForegroundCoverage.unavailable;
    }
    final generation = _generation;
    final authority = _foregroundAuthority;
    final binding = _foregroundBinding;
    final session = _foregroundSession;
    if (authority != null && binding != null && session != null) {
      try {
        final receipt = await _native.foregroundLease(
          requestId: _id(),
          authority: authority,
          binding: binding,
          session: session,
        );
        if (_coverageStillCurrent(generation, authority, binding, session)) {
          return receipt.coverage;
        }
      } catch (_) {
        return AndroidGameStreamForegroundCoverage.unavailable;
      }
    }
    final pairingAuthority = _pairingAuthority;
    final discovery = _discovery;
    final intent = _pairingIntent;
    if (pairingAuthority != null && discovery != null && intent != null) {
      try {
        final receipt = await _native.pairingPrompt(
          requestId: _id(),
          authority: pairingAuthority,
          discovery: discovery,
          intent: intent,
        );
        if (!_disposed &&
            generation == _generation &&
            identical(pairingAuthority, _pairingAuthority) &&
            identical(discovery, _discovery) &&
            identical(intent, _pairingIntent) &&
            _coverageCurrent()) {
          return receipt.coverage;
        }
      } catch (_) {
        return AndroidGameStreamForegroundCoverage.unavailable;
      }
    }
    return AndroidGameStreamForegroundCoverage.unavailable;
  }

  bool _coverageStillCurrent(
    int generation,
    AndroidGameStreamAuthorityV2 authority,
    AndroidGameStreamResolvedBinding binding,
    CoreGameStreamSession session,
  ) =>
      !_disposed &&
      generation == _generation &&
      identical(authority, _foregroundAuthority) &&
      identical(binding, _foregroundBinding) &&
      identical(session, _foregroundSession) &&
      _coverageCurrent();

  Future<void> _recoverEffect(
    GameStreamPendingOperation pending,
    AndroidGameStreamAuthorityV2 authority,
    int generation,
  ) async {
    switch (pending) {
      case GameStreamPairingRecovery():
        await _recoverPairing(pending, authority, generation);
      case GameStreamCatalogRecovery():
        await _recoverCatalog(pending, authority, generation);
      case GameStreamSessionBindRecovery():
        await _recoverSessionBind(pending, authority, generation);
      case GameStreamStopCleanupRecovery():
        await _recoverStopCleanup(pending, authority, generation);
      case GameStreamRevocationPrepareRecovery():
        await _recoverRevocationPrepare(pending, authority, generation);
      case GameStreamRevocationReadyRecovery():
        await _recoverRevocationReady(pending, authority, generation);
      case GameStreamRevocationRecovery():
        await _recoverRevocation(pending, authority, generation);
      case GameStreamRecoveryRecord():
        throw const GameStreamException('invalid_recovery_record');
    }
  }

  Future<void> _recoverStopCleanup(
    GameStreamStopCleanupRecovery record,
    AndroidGameStreamAuthorityV2 authority,
    int generation,
  ) async {
    if (record.accountRevision != authority.accountRevision) {
      throw const GameStreamException('stale_account_authority');
    }
    final session = await _core.readSession(record.sessionId);
    _assertCurrent(generation);
    if (session.state == 'unknown') {
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.outcomeUnknown,
          activeSession: session,
          errorCode: 'stop_cleanup_unknown',
        ),
      );
      return;
    }
    final command = await _core.readCommand(session, record.commandId);
    _assertCurrent(generation);
    if (command.intent != 'stop' ||
        command.state != 'native_observed' ||
        command.result != 'stopped') {
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.outcomeUnknown,
          activeSession: session,
          lastCommand: command,
          errorCode: 'stop_cleanup_unknown',
        ),
      );
      return;
    }
    final cleaned = await _retireStopCleanup(record, session);
    _assertCurrent(generation);
    if (cleaned) {
      _foregroundAuthority = null;
      _foregroundBinding = null;
      _foregroundSession = null;
    }
    _set(
      _state.copyWith(
        phase: cleaned
            ? GameStreamClientPhase.idle
            : GameStreamClientPhase.outcomeUnknown,
        activeSession: cleaned ? null : session,
        clearActiveSession: cleaned,
        lastCommand: command,
        errorCode: cleaned ? null : 'stop_cleanup_unknown',
        clearError: cleaned,
      ),
    );
  }

  Future<void> _recoverSessionBind(
    GameStreamSessionBindRecovery record,
    AndroidGameStreamAuthorityV2 authority,
    int generation,
  ) async {
    if (record.accountRevision != authority.accountRevision) {
      throw const GameStreamException('stale_account_authority');
    }
    var currentRecord = record;
    var nativeRetired = record.nativeRetired;
    if (!nativeRetired) {
      try {
        await _native.retireV2(
          sessionId: record.sessionId,
          epoch: record.sessionRevision,
        );
        nativeRetired = true;
        currentRecord = record.withNativeRetired();
        await _recoveryStore.writeAny(currentRecord);
      } catch (_) {
        // A generic channel failure cannot prove that a possibly accepted bind
        // is absent or fenced. Preserve recovery for another retirement read.
        nativeRetired = false;
        currentRecord = record;
      }
    }
    final session = await _core.readSession(record.sessionId);
    _assertCurrent(generation);
    if (session.state == 'retired') {
      if (nativeRetired) {
        await _recoveryStore.clearAny(currentRecord);
        _set(
          _state.copyWith(phase: GameStreamClientPhase.idle, clearError: true),
        );
      } else {
        _set(
          _state.copyWith(
            phase: GameStreamClientPhase.outcomeUnknown,
            activeSession: session,
            errorCode: 'session_bind_cleanup_unknown',
          ),
        );
      }
      return;
    }
    if (session.state != 'open' || session.revision != record.sessionRevision) {
      if (nativeRetired) {
        await _recoveryStore.clearAny(currentRecord);
      }
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.outcomeUnknown,
          activeSession: session,
          errorCode: nativeRetired
              ? 'recovered_session_retired'
              : 'session_bind_cleanup_unknown',
        ),
      );
      return;
    }
    final cleaned = await _retirePendingBind(
      currentRecord,
      session,
      nativeAlreadyRetired: nativeRetired,
    );
    _assertCurrent(generation);
    _set(
      _state.copyWith(
        phase: cleaned
            ? GameStreamClientPhase.idle
            : GameStreamClientPhase.outcomeUnknown,
        activeSession: cleaned ? null : session,
        clearActiveSession: cleaned,
        errorCode: cleaned ? null : 'session_bind_cleanup_unknown',
        clearError: cleaned,
      ),
    );
  }

  Future<void> _recoverPairing(
    GameStreamPairingRecovery record,
    AndroidGameStreamAuthorityV2 authority,
    int generation,
  ) async {
    if (record.accountRevision != authority.accountRevision) {
      throw const GameStreamException('stale_account_authority');
    }
    if (record.authorityRetirementPending ||
        record.authorityRetired ||
        !record.pairingDispatched) {
      var current = record;
      if (!current.authorityRetired) {
        current = await _retirePairingAuthority(current);
        _assertCurrent(generation);
      }
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.outcomeUnknown,
          errorCode: 'pairing_authority_retired',
        ),
      );
      return;
    }
    final native = await _native.reconcilePairing(
      requestId: _id(),
      authority: record.authority,
      pairingId: record.pairingId,
    );
    _assertCurrent(generation);
    final observation = native?.observation;
    if (native == null || native.state == 'unknown') {
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.outcomeUnknown,
          errorCode: 'pairing_outcome_unknown',
        ),
      );
      return;
    }
    if (native.state == 'rejected' || observation == null) {
      final retired = await _retirePairingAuthority(record);
      _assertCurrent(generation);
      await _recoveryStore.clearAny(retired);
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.error,
          errorCode: 'pairing_rejected',
        ),
      );
      return;
    }
    final intent = CoreGameStreamPairingIntent.recovery(
      id: record.pairingId,
      revision: record.pairingRevision,
      pairingGrant: record.pairingGrant,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        record.expiresAtMillis,
        isUtc: true,
      ),
    );
    final registration = await _core.completePairing(intent, observation);
    _assertCurrent(generation);
    await _native.commitRegistration(
      requestId: _id(),
      authority: record.authority,
      discovery: AndroidGameStreamDiscovery.recovery(observation),
      registration: registration,
    );
    _assertCurrent(generation);
    await _recoveryStore.clearAny(record);
    final hosts = await _core.hosts();
    _assertCurrent(generation);
    final registeredHost = _singleWhereOrNull(
      hosts.hosts,
      (item) => _hostEqual(item, registration.host),
    );
    if (registeredHost == null) {
      throw const GameStreamException('pairing_readback_mismatch');
    }
    _set(
      _state.copyWith(
        phase: GameStreamClientPhase.idle,
        accountRevision: hosts.accountRevision,
        hosts: hosts.hosts,
        selectedHost: registeredHost,
        apps: registration.apps,
        clearSelectedApp: true,
        clearCapabilities: true,
        clearSelectedQuality: true,
        clearError: true,
      ),
    );
  }

  Future<GameStreamPairingRecovery> _retirePairingAuthority(
    GameStreamPairingRecovery record, {
    AndroidGameStreamDiscovery? discovery,
  }) async {
    var current = record;
    if (current.authorityRetired) return current;
    Object? storageFailure;
    if (!current.authorityRetirementPending) {
      current = current.withAuthorityRetirementPending();
      try {
        await _recoveryStore.writeAny(current);
      } catch (error) {
        storageFailure = error;
      }
    }
    await _native.retireAuthority(
      requestId: current.pairingId,
      authority: current.authority,
      nativeBindingId: discovery?.nativeBindingId,
      bindingRevision: discovery?.bindingRevision,
    );
    current = current.withAuthorityRetired();
    try {
      await _recoveryStore.writeAny(current);
    } catch (error) {
      storageFailure ??= error;
    }
    if (storageFailure != null) throw storageFailure;
    return current;
  }

  Future<GameStreamCatalogRecovery> _retireCatalogAuthority(
    GameStreamCatalogRecovery record,
  ) async {
    var current = record;
    if (current.authorityRetired) return current;
    Object? storageFailure;
    if (!current.authorityRetirementPending) {
      current = current.withAuthorityRetirementPending();
      try {
        await _recoveryStore.writeAny(current);
      } catch (error) {
        storageFailure = error;
      }
    }
    await _native.retireAuthority(
      requestId: current.observationId,
      authority: current.authority,
      nativeBindingId: current.nativeBindingId,
      bindingRevision: current.bindingRevision,
    );
    current = current.withAuthorityRetired();
    try {
      await _recoveryStore.writeAny(current);
    } catch (error) {
      storageFailure ??= error;
    }
    if (storageFailure != null) throw storageFailure;
    return current;
  }

  Future<void> _recoverCatalog(
    GameStreamCatalogRecovery record,
    AndroidGameStreamAuthorityV2 authority,
    int generation,
  ) async {
    if (record.accountRevision != authority.accountRevision) {
      throw const GameStreamException('stale_account_authority');
    }
    if (record.authorityRetirementPending ||
        record.authorityRetired ||
        !record.hasBinding ||
        !record.catalogDispatched) {
      var current = record;
      if (!current.authorityRetired) {
        current = await _retireCatalogAuthority(current);
        _assertCurrent(generation);
      }
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.outcomeUnknown,
          errorCode: 'catalog_authority_retired',
        ),
      );
      return;
    }
    final native = await _native.reconcileCatalog(
      requestId: _id(),
      authority: record.authority,
      catalogObservationId: record.observationId,
    );
    _assertCurrent(generation);
    final observation = native?.observation;
    if (native == null || native.state != 'observed' || observation == null) {
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.outcomeUnknown,
          errorCode: 'catalog_outcome_unknown',
        ),
      );
      return;
    }
    final intent = CoreGameStreamCatalogIntent.recovery(
      id: record.observationId,
      hostId: record.host.id,
      revision: record.observationRevision,
      catalogGrant: record.catalogGrant,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        record.expiresAtMillis,
        isUtc: true,
      ),
    );
    final update = await _core.completeCatalogObservation(
      record.host,
      intent,
      observation,
    );
    _assertCurrent(generation);
    await _native.commitCatalogRegistration(
      requestId: _id(),
      authority: record.authority,
      binding: AndroidGameStreamHostBinding.recovery(
        nativeBindingId: record.nativeBindingId!,
        bindingRevision: record.bindingRevision!,
        registrationRevision: record.registrationRevision!,
        hostId: record.host.id,
        engineRevision: record.engineRevision!,
      ),
      update: update,
    );
    _assertCurrent(generation);
    await _recoveryStore.clearAny(record);
    final hosts = await _core.hosts();
    _assertCurrent(generation);
    final host = _singleWhereOrNull(
      hosts.hosts,
      (item) => item.id == record.host.id,
    );
    if (host == null || host.catalogRevision != update.catalogRevision) {
      throw const GameStreamException('catalog_readback_mismatch');
    }
    final catalog = await _core.apps(host);
    _assertCurrent(generation);
    _set(
      _state.copyWith(
        phase: GameStreamClientPhase.ready,
        accountRevision: hosts.accountRevision,
        hosts: hosts.hosts,
        selectedHost: host,
        apps: catalog.apps,
        clearSelectedApp: true,
        clearCapabilities: true,
        clearSelectedQuality: true,
        clearActiveSession: true,
        clearLastCommand: true,
        clearError: true,
      ),
    );
  }

  Future<void> _recoverRevocation(
    GameStreamRevocationRecovery record,
    AndroidGameStreamAuthorityV2 authority,
    int generation,
  ) async {
    if (record.accountRevision != authority.accountRevision) {
      throw const GameStreamException('stale_account_authority');
    }
    final native = await _native.reconcileRevocation(
      requestId: _id(),
      authority: authority,
      revocationId: record.revocationId,
    );
    _assertCurrent(generation);
    if (native == null) {
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.outcomeUnknown,
          errorCode: 'revocation_outcome_unknown',
        ),
      );
      return;
    }
    final revocation = CoreGameStreamRevocation.recovery(
      id: record.revocationId,
      hostId: record.hostId,
      hostRevision: record.hostRevision,
    );
    final completed = await _core.completeRevocation(
      revocation,
      state: native.state,
      readbackRevision: native.readbackRevision,
      nativeReceiptDigest: native.nativeReceiptDigest,
    );
    _assertCurrent(generation);
    if (completed.state != 'local_cleared') {
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.outcomeUnknown,
          errorCode: 'revocation_outcome_unknown',
        ),
      );
      return;
    }
    await _recoveryStore.clearAny(record);
    final hosts = await _core.hosts();
    _assertCurrent(generation);
    _set(
      _state.copyWith(
        phase: GameStreamClientPhase.idle,
        accountRevision: hosts.accountRevision,
        hosts: hosts.hosts,
        clearSelectedHost: true,
        apps: const [],
        clearSelectedApp: true,
        clearCapabilities: true,
        clearSelectedQuality: true,
        clearActiveSession: true,
        clearLastCommand: true,
        clearError: true,
      ),
    );
  }

  Future<void> _recoverRevocationPrepare(
    GameStreamRevocationPrepareRecovery record,
    AndroidGameStreamAuthorityV2 authority,
    int generation,
  ) async {
    if (record.accountRevision != authority.accountRevision) {
      throw const GameStreamException('stale_account_authority');
    }
    final revocation = await _core.revoke(
      record.host,
      requestKey: record.requestKey,
    );
    _assertCurrent(generation);
    final ready = GameStreamRevocationReadyRecovery(
      scope: record.scope,
      accountRevision: record.accountRevision,
      host: record.host,
      revocationId: revocation.id,
      retiredHostRevision: revocation.hostRevision,
    );
    await _recoveryStore.writeAny(ready);
    _assertCurrent(generation);
    await _recoverRevocationReady(ready, authority, generation);
  }

  Future<void> _recoverRevocationReady(
    GameStreamRevocationReadyRecovery record,
    AndroidGameStreamAuthorityV2 authority,
    int generation,
  ) async {
    if (record.accountRevision != authority.accountRevision) {
      throw const GameStreamException('stale_account_authority');
    }
    final revocation = CoreGameStreamRevocation.recovery(
      id: record.revocationId,
      hostId: record.host.id,
      hostRevision: record.retiredHostRevision,
    );
    final dispatching = GameStreamRevocationRecovery(
      scope: record.scope,
      accountRevision: record.accountRevision,
      revocationId: record.revocationId,
      hostId: record.host.id,
      hostRevision: record.retiredHostRevision,
    );
    await _recoveryStore.writeAny(dispatching);
    _assertCurrent(generation);
    AndroidGameStreamRevocationReceipt? native;
    try {
      native = await _native.revokePairing(
        requestId: _id(),
        authority: authority,
        revocation: revocation,
        host: record.host,
      );
    } catch (_) {
      _assertCurrent(generation);
      native = await _native.reconcileRevocation(
        requestId: _id(),
        authority: authority,
        revocationId: record.revocationId,
      );
    }
    _assertCurrent(generation);
    if (native == null) {
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.outcomeUnknown,
          errorCode: 'revocation_outcome_unknown',
        ),
      );
      return;
    }
    final completed = await _core.completeRevocation(
      revocation,
      state: native.state,
      readbackRevision: native.readbackRevision,
      nativeReceiptDigest: native.nativeReceiptDigest,
    );
    _assertCurrent(generation);
    if (completed.state != 'local_cleared') {
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.outcomeUnknown,
          errorCode: 'revocation_outcome_unknown',
        ),
      );
      return;
    }
    await _recoveryStore.clearAny(dispatching);
    final hosts = await _core.hosts();
    _assertCurrent(generation);
    _set(
      _state.copyWith(
        phase: GameStreamClientPhase.idle,
        accountRevision: hosts.accountRevision,
        hosts: hosts.hosts,
        clearSelectedHost: true,
        apps: const [],
        clearSelectedApp: true,
        clearCapabilities: true,
        clearSelectedQuality: true,
        clearActiveSession: true,
        clearLastCommand: true,
        clearError: true,
      ),
    );
  }

  Future<void> revoke(CoreGameStreamHost host) async {
    _assertEffectAvailable();
    final accountRevision = _state.accountRevision;
    if (accountRevision == null || !_sameHost(_state.hosts, host)) {
      throw const GameStreamException('stale_host');
    }
    if (_state.activeSession != null &&
        _state.phase != GameStreamClientPhase.ready) {
      throw const GameStreamException('session_busy');
    }
    final generation = _begin(GameStreamClientPhase.revoking);
    try {
      final authority = _authority(accountRevision);
      final prepare = GameStreamRevocationPrepareRecovery(
        scope: _recoveryScope(authority),
        accountRevision: accountRevision,
        requestKey: 'revoke-${_id()}',
        host: host,
      );
      await _recoveryStore.writeAny(prepare);
      _assertCurrent(generation);
      final revocation = await _core.revoke(
        host,
        requestKey: prepare.requestKey,
      );
      _assertCurrent(generation);
      final ready = GameStreamRevocationReadyRecovery(
        scope: _recoveryScope(authority),
        accountRevision: accountRevision,
        host: host,
        revocationId: revocation.id,
        retiredHostRevision: revocation.hostRevision,
      );
      await _recoveryStore.writeAny(ready);
      _assertCurrent(generation);
      final recovery = GameStreamRevocationRecovery(
        scope: _recoveryScope(authority),
        accountRevision: accountRevision,
        revocationId: revocation.id,
        hostId: revocation.hostId,
        hostRevision: revocation.hostRevision,
      );
      await _recoveryStore.writeAny(recovery);
      _assertCurrent(generation);
      AndroidGameStreamRevocationReceipt? native;
      try {
        native = await _native.revokePairing(
          requestId: _id(),
          authority: authority,
          revocation: revocation,
          host: host,
        );
      } catch (_) {
        _assertCurrent(generation);
        try {
          native = await _native.reconcileRevocation(
            requestId: _id(),
            authority: authority,
            revocationId: revocation.id,
          );
        } catch (_) {
          native = null;
        }
      }
      _assertCurrent(generation);
      CoreGameStreamRevocation completed;
      try {
        completed = await _core.completeRevocation(
          revocation,
          state: native?.state ?? 'unknown',
          readbackRevision: native?.readbackRevision,
          nativeReceiptDigest: native?.nativeReceiptDigest,
        );
      } catch (_) {
        _assertCurrent(generation);
        _set(
          _state.copyWith(
            phase: GameStreamClientPhase.outcomeUnknown,
            errorCode: 'revocation_outcome_unknown',
          ),
        );
        return;
      }
      _assertCurrent(generation);
      if (completed.state != 'local_cleared') {
        _set(
          _state.copyWith(
            phase: GameStreamClientPhase.outcomeUnknown,
            errorCode: 'revocation_outcome_unknown',
          ),
        );
        return;
      }
      await _recoveryStore.clearAny(recovery);
      final hosts = await _core.hosts();
      _assertCurrent(generation);
      _binding = null;
      _set(
        _state.copyWith(
          phase: GameStreamClientPhase.idle,
          accountRevision: hosts.accountRevision,
          hosts: hosts.hosts,
          clearSelectedHost: true,
          apps: const [],
          clearSelectedApp: true,
          clearCapabilities: true,
          clearSelectedQuality: true,
          clearActiveSession: true,
          clearLastCommand: true,
          clearError: true,
        ),
      );
    } catch (error) {
      _fail(generation, error);
    }
  }

  Future<void> retire() => _retire(clearState: true);

  Future<void> _retire({required bool clearState}) async {
    _generation += 1;
    final session = _state.activeSession;
    final leaseSession = _foregroundSession ?? session;
    final leaseAuthority = _foregroundAuthority;
    final authorityLease = _pairingAuthority;
    final authorityRetirementId = _authorityRetirementId ?? _pairingIntent?.id;
    final authorityBindingId =
        _authorityRetirementBindingId ?? _discovery?.nativeBindingId;
    final authorityBindingRevision =
        _authorityRetirementBindingRevision ?? _discovery?.bindingRevision;
    GameStreamPendingOperation? recovery;
    Object? storageFailure;
    try {
      recovery = await _recoveryStore.readStored();
    } catch (error) {
      storageFailure = error;
    }
    if (leaseSession != null) {
      if (recovery == null && storageFailure == null) {
        if (leaseAuthority == null) {
          storageFailure = const GameStreamException('session_cleanup_unknown');
        } else {
          final scope = _recoveryScope(leaseAuthority);
          recovery = GameStreamSessionBindRecovery(
            scope: scope,
            accountRevision: leaseAuthority.accountRevision,
            sessionId: leaseSession.id,
            sessionRevision: leaseSession.revision,
            retireRequestKey: 'retire-route-${_id()}',
          );
          try {
            await _recoveryStore.writeAny(recovery);
          } catch (error) {
            storageFailure = error;
          }
        }
      } else if (leaseAuthority != null &&
          recovery != null &&
          !recovery.scope.same(_recoveryScope(leaseAuthority))) {
        storageFailure = const GameStreamException('recovery_scope_changed');
      }
      if (recovery != null && !_recoveryCoversSession(recovery, leaseSession)) {
        storageFailure = const GameStreamException('operation_busy');
      }
    } else if (authorityLease != null &&
        storageFailure == null &&
        recovery is! GameStreamPairingRecovery &&
        recovery is! GameStreamCatalogRecovery) {
      storageFailure = const GameStreamException('authority_cleanup_unknown');
    }
    _pairingIntent = null;
    _discovery = null;
    _binding = null;
    _pairingAuthority = null;
    _clearAuthorityRetirementLease();
    _foregroundAuthority = null;
    _foregroundBinding = null;
    _foregroundSession = null;
    Object? nativeFailure;
    var nativeRetired = false;
    if (leaseSession == null &&
        (recovery is GameStreamPairingRecovery ||
            recovery is GameStreamCatalogRecovery ||
            authorityLease != null)) {
      try {
        var retireAuthority = authorityLease;
        var retireId = authorityRetirementId;
        var bindingId = authorityBindingId;
        var bindingRevision = authorityBindingRevision;
        if (recovery case final GameStreamPairingRecovery pair) {
          retireAuthority = pair.authority;
          retireId = pair.pairingId;
          if (!pair.authorityRetired && !pair.authorityRetirementPending) {
            recovery = pair.withAuthorityRetirementPending();
            try {
              await _recoveryStore.writeAny(recovery);
            } catch (error) {
              storageFailure ??= error;
            }
          }
          nativeRetired = pair.authorityRetired;
        } else if (recovery case final GameStreamCatalogRecovery catalog) {
          retireAuthority = catalog.authority;
          retireId = catalog.observationId;
          bindingId = catalog.nativeBindingId ?? bindingId;
          bindingRevision = catalog.bindingRevision ?? bindingRevision;
          if (!catalog.authorityRetired &&
              !catalog.authorityRetirementPending) {
            recovery = catalog.withAuthorityRetirementPending();
            try {
              await _recoveryStore.writeAny(recovery);
            } catch (error) {
              storageFailure ??= error;
            }
          }
          nativeRetired = catalog.authorityRetired;
        }
        if (!nativeRetired) {
          if (retireAuthority == null || retireId == null) {
            throw const GameStreamException('authority_cleanup_unknown');
          }
          await _native.retireAuthority(
            requestId: retireId,
            authority: retireAuthority,
            nativeBindingId: bindingId,
            bindingRevision: bindingRevision,
          );
          nativeRetired = true;
          final retired = switch (recovery) {
            GameStreamPairingRecovery value => value.withAuthorityRetired(),
            GameStreamCatalogRecovery value => value.withAuthorityRetired(),
            _ => null,
          };
          if (retired != null) {
            recovery = retired;
            try {
              await _recoveryStore.writeAny(retired);
            } catch (error) {
              storageFailure ??= error;
            }
          }
        }
      } catch (error) {
        nativeFailure = error;
      }
    } else if (leaseSession != null) {
      try {
        nativeRetired = _nativeRetired(recovery);
        if (!nativeRetired) {
          await _native.retireV2(
            sessionId: leaseSession.id,
            epoch: leaseSession.revision,
          );
          nativeRetired = true;
          final next = _withNativeRetired(recovery, leaseSession);
          if (next != null) {
            recovery = next;
            try {
              await _recoveryStore.writeAny(next);
            } catch (error) {
              storageFailure ??= error;
            }
          }
        }
      } catch (error) {
        nativeFailure = error;
      }
    }
    var coreRetired = leaseSession == null;
    if (session != null) {
      try {
        final retired = await _core.retireSession(
          session,
          requestKey: recovery == null
              ? 'retire-session-${leaseSession!.id}'
              : _retireRequestKey(recovery),
        );
        coreRetired = retired.id == session.id && retired.state == 'retired';
      } catch (_) {}
    }
    if (nativeRetired &&
        coreRetired &&
        recovery != null &&
        recovery is! GameStreamPairingRecovery &&
        recovery is! GameStreamCatalogRecovery) {
      if (storageFailure == null) await _recoveryStore.clearAny(recovery);
    }
    if (clearState) _set(const GameStreamClientSnapshot());
    if (nativeFailure != null) throw nativeFailure;
    if (storageFailure != null) throw storageFailure;
  }

  /// Retires only the exact locally owned native/Core session after an
  /// uncertain outcome. This never authorizes or redispatches a stop command,
  /// and it does not claim that the provider stream stopped.
  Future<void> closeLocalSession() async {
    _assertRoute();
    final uncertain = _state;
    if (uncertain.phase != GameStreamClientPhase.outcomeUnknown ||
        uncertain.activeSession == null) {
      throw const GameStreamException('local_session_cleanup_unavailable');
    }
    final closingGeneration = _begin(GameStreamClientPhase.closing);
    // `_retire` advances the controller generation once before its first
    // await. No completion from this close attempt may overwrite a successor.
    final retirementGeneration = closingGeneration + 1;

    Object? cleanupFailure;
    try {
      await _retire(clearState: false);
    } catch (error) {
      cleanupFailure = error;
    }
    GameStreamPendingOperation? remaining;
    try {
      remaining = await _recoveryStore.readStored();
    } catch (error) {
      cleanupFailure ??= error;
    }
    bool routeCurrent() {
      try {
        return !_disposed && _current();
      } catch (_) {
        return false;
      }
    }

    if (_generation != retirementGeneration || !routeCurrent()) return;
    if (cleanupFailure != null || remaining != null) {
      _set(
        uncertain.copyWith(
          phase: GameStreamClientPhase.outcomeUnknown,
          errorCode: 'local_session_cleanup_unknown',
        ),
      );
      return;
    }
    _set(const GameStreamClientSnapshot());
    await refresh();
  }

  void _clearAuthorityRetirementLease() {
    _authorityRetirementId = null;
    _authorityRetirementBindingId = null;
    _authorityRetirementBindingRevision = null;
  }

  int _begin(GameStreamClientPhase phase) {
    _assertRoute();
    if (_state.busy) throw const GameStreamException('operation_busy');
    final generation = ++_generation;
    _set(_state.copyWith(phase: phase, clearError: true));
    return generation;
  }

  void _assertEffectAvailable() {
    if (_state.phase == GameStreamClientPhase.outcomeUnknown) {
      throw const GameStreamException('outcome_unknown_requires_reentry');
    }
  }

  void _requirePin(AndroidGameStreamAuthorityV2 authority, bool required) {
    if (required && !authority.satisfiesRequiredPin) {
      throw const GameStreamException('pin_required');
    }
  }

  void _assertCurrent(int generation) {
    _assertRoute();
    if (generation != _generation) {
      throw const GameStreamException('stale_client_operation');
    }
  }

  void _assertRoute() {
    try {
      if (!_disposed && _current()) return;
    } catch (_) {}
    throw const GameStreamException('stale_client_operation');
  }

  void _fail(int generation, Object error) {
    if (_disposed || generation != _generation) return;
    final code = switch (error) {
      GameStreamException failure => failure.code,
      LarenorServerException failure => failure.code,
      _ => 'game_stream_unavailable',
    };
    _set(
      _state.copyWith(
        phase: code.contains('unknown')
            ? GameStreamClientPhase.outcomeUnknown
            : GameStreamClientPhase.error,
        errorCode: code,
      ),
    );
  }

  void _set(GameStreamClientSnapshot value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  String _id() => List<int>.generate(
    16,
    (_) => _random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  @override
  void dispose() {
    _disposed = true;
    _generation += 1;
    _core.retire();
    super.dispose();
  }
}

GameStreamRecoveryScope _recoveryScope(AndroidGameStreamAuthorityV2 value) =>
    GameStreamRecoveryScope(
      coreId: value.coreId,
      homeId: value.homeId,
      accountId: value.accountId,
      familyId: value.familyId,
    );

bool _recoveryCoversSession(
  GameStreamPendingOperation value,
  CoreGameStreamSession session,
) => switch (value) {
  GameStreamRecoveryRecord() =>
    value.sessionId == session.id && value.sessionRevision == session.revision,
  GameStreamSessionBindRecovery() =>
    value.sessionId == session.id && value.sessionRevision == session.revision,
  GameStreamStopCleanupRecovery() =>
    value.sessionId == session.id && value.sessionRevision == session.revision,
  _ => false,
};

bool _exactObservedCommand(
  CoreGameStreamCommand value, {
  required String commandId,
  required String intent,
  required String result,
  required String observationKind,
}) =>
    value.id == commandId &&
    value.intent == intent &&
    value.state == 'native_observed' &&
    value.result == result &&
    value.observationKind == observationKind &&
    value.readbackRevision != null;

bool _nativeRetired(GameStreamPendingOperation? value) => switch (value) {
  GameStreamRecoveryRecord() => value.nativeRetired,
  GameStreamSessionBindRecovery() => value.nativeRetired,
  GameStreamStopCleanupRecovery() => value.nativeRetired,
  _ => false,
};

GameStreamPendingOperation? _withNativeRetired(
  GameStreamPendingOperation? value,
  CoreGameStreamSession session,
) {
  if (value == null || !_recoveryCoversSession(value, session)) return null;
  return switch (value) {
    GameStreamRecoveryRecord() => value.withNativeRetired(),
    GameStreamSessionBindRecovery() => value.withNativeRetired(),
    GameStreamStopCleanupRecovery() => value.withNativeRetired(),
    _ => null,
  };
}

String _retireRequestKey(GameStreamPendingOperation? value) => switch (value) {
  GameStreamSessionBindRecovery() => value.retireRequestKey,
  GameStreamStopCleanupRecovery() => value.retireRequestKey,
  GameStreamRecoveryRecord() => 'retire-command-${value.commandId}',
  _ => throw const GameStreamException('session_cleanup_unknown'),
};

bool _sameHost(List<CoreGameStreamHost> values, CoreGameStreamHost expected) =>
    values.any((value) => identical(value, expected));

bool _sameApp(List<CoreGameStreamApp> values, CoreGameStreamApp expected) =>
    values.any((value) => identical(value, expected));

bool _hostEqual(CoreGameStreamHost left, CoreGameStreamHost right) =>
    left.id == right.id &&
    left.revision == right.revision &&
    left.pairingRevision == right.pairingRevision &&
    left.catalogRevision == right.catalogRevision;

bool _appEqual(CoreGameStreamApp left, CoreGameStreamApp right) =>
    left.id == right.id &&
    left.hostId == right.hostId &&
    left.revision == right.revision;

bool _qualityEqual(
  AndroidGameStreamQualityOption left,
  AndroidGameStreamQualityOption right,
) => _sameSelectedQuality(left.selectedQuality, right.selectedQuality);

bool _sameSelectedQuality(
  CoreGameStreamSelectedQuality left,
  CoreGameStreamSelectedQuality right,
) => left.toJson().toString() == right.toJson().toString();

T? _singleWhereOrNull<T>(Iterable<T> values, bool Function(T) test) {
  T? result;
  var found = false;
  for (final value in values) {
    if (!test(value)) continue;
    if (found) return null;
    result = value;
    found = true;
  }
  return result;
}
