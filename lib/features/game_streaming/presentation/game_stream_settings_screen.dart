import 'dart:async';
import 'dart:math';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../settings/presentation/panes/settings_nav_row.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../../server/providers/server_providers.dart';
import '../data/android_game_stream_port.dart';
import '../data/android_game_stream_v2_port.dart';
import '../data/core_game_stream_api.dart';
import '../data/game_stream_client_controller.dart';
import '../domain/game_stream_session.dart';

final class GameStreamGateAuthority {
  const GameStreamGateAuthority({
    required this.pinRevision,
    required this.pinConfigured,
    required this.pinUnlocked,
  });

  final int pinRevision;
  final bool pinConfigured, pinUnlocked;
}

@visibleForTesting
typedef GameStreamClientFactory = GameStreamClientController Function({
  required CoreGameStreamApi core,
  required GameStreamNativeV2Port native,
  required AndroidGameStreamAuthorityV2 Function(int accountRevision) authority,
  required bool Function() isCurrent,
  required bool Function() isCoverageCurrent,
});

/// Shares one strict native ownership query between the settings gate and the
/// game route when Android covers Flutter with an owned prompt or Game task.
final class GameStreamForegroundCoverageGuard {
  Future<AndroidGameStreamForegroundCoverage> Function()? _query;
  Future<AndroidGameStreamForegroundCoverage>? _pending;
  Object? _owner;

  void attach(
    Object owner,
    Future<AndroidGameStreamForegroundCoverage> Function() query,
  ) {
    _owner = owner;
    _query = query;
    _pending = null;
  }

  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _query = null;
    _pending = null;
  }

  Future<AndroidGameStreamForegroundCoverage> query() {
    final existing = _pending;
    if (existing != null) return existing;
    final callback = _query;
    if (callback == null) {
      return Future.value(AndroidGameStreamForegroundCoverage.unavailable);
    }
    late final Future<AndroidGameStreamForegroundCoverage> pending;
    pending = Future.sync(callback)
        .catchError((_) => AndroidGameStreamForegroundCoverage.unavailable)
        .whenComplete(() {
          if (identical(_pending, pending)) _pending = null;
        });
    _pending = pending;
    return pending;
  }
}

class GameStreamSettingsScreen extends ConsumerStatefulWidget {
  const GameStreamSettingsScreen({
    super.key,
    this.port,
    this.v2Port,
    this.gateCurrent,
    this.gateAuthority,
    this.coverageGateCurrent,
    this.foregroundCoverageGuard,
    this.clientFactory,
  });

  final GameStreamCapabilityPort? port;
  final GameStreamNativeV2Port? v2Port;
  final bool Function()? gateCurrent;
  final GameStreamGateAuthority? Function()? gateAuthority;
  final bool Function()? coverageGateCurrent;
  final GameStreamForegroundCoverageGuard? foregroundCoverageGuard;
  @visibleForTesting
  final GameStreamClientFactory? clientFactory;

  @override
  ConsumerState<GameStreamSettingsScreen> createState() =>
      _GameStreamSettingsScreenState();
}

class _GameStreamSettingsScreenState
    extends ConsumerState<GameStreamSettingsScreen>
    with WidgetsBindingObserver {
  late final GameStreamCapabilityPort _port;
  late final GameStreamNativeV2Port _v2Port;
  final String _clientInstanceId = _newClientInstanceId();

  @visibleForTesting
  String get clientInstanceIdForTesting => _clientInstanceId;
  @visibleForTesting
  GameStreamClientSnapshot? get clientStateForTesting => _client?.state;
  AppInteractionController? _interaction;
  ModalRoute<dynamic>? _route;
  int _generation = 0;
  int _interactionEpoch = 0;
  int _routeRevision = 1;
  int _lifecycleRevision = 1;
  int _idleRevision = 1;
  int _interactionRevision = 1;
  int _coverageEpoch = 0;
  bool _resumed = true;
  bool _focused = true;
  bool _routeVisible = false;
  bool _loading = false;
  bool _started = false;
  AndroidGameStreamCapabilities? _capabilities;
  CoreGameStreamHosts? _hosts;
  String? _error;
  String? _hostsError;
  bool _providerError = false;
  bool _openingProvider = false;
  AndroidGameStreamForegroundCoverage _foregroundCoverage =
      AndroidGameStreamForegroundCoverage.unavailable;
  GameStreamClientController? _client;
  LarenorServerApi? _clientTransport;
  ServerSession? _sessionOwner;
  Future<void>? _clientRetirement;
  late final ServerAccountController _serverAccount;

  @override
  void initState() {
    super.initState();
    _port = widget.port ?? AndroidGameStreamPort();
    _v2Port = widget.v2Port ?? AndroidGameStreamV2Port();
    _serverAccount = ref.read(serverAccountControllerProvider);
    _serverAccount.addListener(_serverAccountChanged);
    WidgetsBinding.instance.addObserver(this);
    widget.foregroundCoverageGuard?.attach(this, _queryForegroundCoverage);
  }

  void _serverAccountChanged() {
    final owner = _sessionOwner;
    if (!mounted || owner == null || identical(_serverAccount.session, owner)) {
      return;
    }
    _invalidate(clearStatus: true);
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final interaction = AppInteractionScope.maybeOf(context);
    if (!identical(interaction, _interaction)) {
      _interaction?.removeListener(_interactionChanged);
      _interaction = interaction;
      _interactionEpoch = interaction?.epoch ?? 0;
      interaction?.addListener(_interactionChanged);
      _invalidate(clearStatus: false);
    }
    final route = ModalRoute.of(context);
    if (_route != null && !identical(route, _route)) {
      _invalidate(clearStatus: true);
    }
    _route = route;
    final routeVisible =
        route?.isCurrent == true && TickerMode.valuesOf(context).enabled;
    if (routeVisible != _routeVisible) _routeRevision += 1;
    if (_routeVisible && !routeVisible) {
      _invalidate(clearStatus: true);
    }
    _routeVisible = routeVisible;
    if (!_started) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_refresh());
      });
    }
  }

  void _interactionChanged() {
    final epoch = _interaction?.epoch ?? 0;
    if (epoch == _interactionEpoch) return;
    _interactionEpoch = epoch;
    _idleRevision += 1;
    _interactionRevision += 1;
    final lost = _interaction?.active == false;
    unawaited(_handleInteractionChange(lost: lost));
    if (mounted) setState(() {});
  }

  Future<void> _handleInteractionChange({required bool lost}) async {
    if (!mounted) return;
    if (!lost) {
      await _handleForegroundReturn();
      return;
    }
    await _retainOnlyExactForegroundCoverage();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleRevision += 1;
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed) {
      unawaited(_handleForegroundReturn());
    } else {
      unawaited(_retainOnlyExactForegroundCoverage());
    }
    if (mounted) setState(() {});
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (!mounted || event.viewId != View.of(context).viewId) return;
    _focused = event.state == ViewFocusState.focused;
    _lifecycleRevision += 1;
    if (_focused) {
      unawaited(_handleForegroundReturn());
    } else {
      unawaited(_retainOnlyExactForegroundCoverage());
    }
    setState(() {});
  }

  Future<void> _retainOnlyExactForegroundCoverage() async {
    final epoch = ++_coverageEpoch;
    final coverage =
        await (widget.foregroundCoverageGuard?.query() ??
            _queryForegroundCoverage());
    if (!mounted || epoch != _coverageEpoch) return;
    if (coverage == AndroidGameStreamForegroundCoverage.unavailable) {
      _invalidate(clearStatus: true);
      return;
    }
    _foregroundCoverage = coverage;
  }

  Future<void> _handleForegroundReturn() async {
    final prior = _foregroundCoverage;
    if (prior == AndroidGameStreamForegroundCoverage.unavailable ||
        !_resumed ||
        !_focused ||
        _interaction?.active == false) {
      return;
    }
    final epoch = ++_coverageEpoch;
    final coverage =
        await (widget.foregroundCoverageGuard?.query() ??
            _queryForegroundCoverage());
    if (!mounted || epoch != _coverageEpoch) return;
    _foregroundCoverage = coverage;
    if (prior == AndroidGameStreamForegroundCoverage.game &&
        coverage == AndroidGameStreamForegroundCoverage.unavailable) {
      _invalidate(clearStatus: true);
    }
  }

  void _invalidate({required bool clearStatus}) {
    _coverageEpoch += 1;
    _foregroundCoverage = AndroidGameStreamForegroundCoverage.unavailable;
    _generation += 1;
    _loading = false;
    // Opening another app normally retires this route before its method-channel
    // reply arrives. That old attempt must not leave the next visit busy.
    _openingProvider = false;
    if (clearStatus) {
      _capabilities = null;
      _hosts = null;
      _error = null;
      _hostsError = null;
      _providerError = false;
      unawaited(_retireClient());
    }
  }

  Future<AndroidGameStreamForegroundCoverage> _queryForegroundCoverage() async {
    final client = _client;
    final owner = _sessionOwner;
    final generation = _generation;
    if (client == null ||
        owner == null ||
        !_coverageCurrent(generation, owner)) {
      return AndroidGameStreamForegroundCoverage.unavailable;
    }
    final coverage = await client.foregroundCoverage();
    if (!_coverageCurrent(generation, owner)) {
      return AndroidGameStreamForegroundCoverage.unavailable;
    }
    return coverage;
  }

  bool _coverageCurrent(int generation, ServerSession owner) {
    try {
      final account = ref.read(serverAccountControllerProvider);
      return mounted &&
          generation == _generation &&
          identical(account.session, owner) &&
          account.initialized &&
          !account.working &&
          owner.context != null &&
          owner.sessionFamilyId != null &&
          widget.coverageGateCurrent?.call() == true &&
          identical(ModalRoute.of(context), _route) &&
          _route?.isCurrent == true &&
          TickerMode.valuesOf(context).enabled;
    } catch (_) {
      return false;
    }
  }

  AndroidGameStreamAuthorityV2 _nativeAuthority(int accountRevision) {
    final gate = widget.gateAuthority?.call();
    final session = _sessionOwner;
    final context = session?.context;
    final familyId = session?.sessionFamilyId;
    if (gate == null ||
        session == null ||
        context == null ||
        familyId == null ||
        !_interactiveCurrent(_generation)) {
      throw const GameStreamException('game_stream_authority_changed');
    }
    return AndroidGameStreamAuthorityV2(
      clientInstanceId: _clientInstanceId,
      coreId: context.coreId,
      homeId: context.homeId,
      accountId: session.user.id,
      familyId: familyId,
      accountRevision: accountRevision,
      pinRevision: gate.pinRevision,
      pinConfigured: gate.pinConfigured,
      pinUnlocked: gate.pinUnlocked,
      routeRevision: _routeRevision,
      lifecycleRevision: _lifecycleRevision,
      idleRevision: _idleRevision,
      interactionRevision: _interactionRevision,
    );
  }

  Future<void> _retireClient() {
    final existing = _clientRetirement;
    if (existing != null) return existing;
    late final Future<void> retirement;
    retirement = _retireClientOwned().whenComplete(() {
      if (identical(_clientRetirement, retirement)) {
        _clientRetirement = null;
      }
    });
    _clientRetirement = retirement;
    return retirement;
  }

  Future<void> _retireClientOwned() async {
    final client = _client;
    final transport = _clientTransport;
    _client = null;
    _clientTransport = null;
    _sessionOwner = null;
    if (client != null) {
      client.removeListener(_clientChanged);
      try {
        await client.retire();
      } catch (_) {}
      client.dispose();
    }
    transport?.close();
    if (_v2Port is AndroidGameStreamV2Port) {
      _v2Port.retireLocally();
    }
  }

  void _clientChanged() {
    if (!mounted) return;
    final hosts = _client?.state;
    if (hosts?.accountRevision != null) {
      _hosts = CoreGameStreamHosts(
        accountRevision: hosts!.accountRevision!,
        hosts: hosts.hosts,
      );
    } else {
      _hosts = null;
    }
    setState(() {});
  }

  bool _current(int generation) {
    try {
      final routeCurrent =
          mounted &&
          generation == _generation &&
          identical(ModalRoute.of(context), _route) &&
          _route?.isCurrent == true &&
          TickerMode.valuesOf(context).enabled;
      final interactive =
          _resumed &&
          _focused &&
          _interaction?.active != false &&
          (_interaction?.epoch ?? 0) == _interactionEpoch &&
          widget.gateCurrent?.call() == true;
      final covered =
          _foregroundCoverage !=
              AndroidGameStreamForegroundCoverage.unavailable &&
          widget.coverageGateCurrent?.call() == true;
      return routeCurrent && (interactive || covered);
    } catch (_) {
      return false;
    }
  }

  bool _interactiveCurrent(int generation) {
    try {
      return mounted &&
          generation == _generation &&
          _resumed &&
          _focused &&
          _interaction?.active != false &&
          (_interaction?.epoch ?? 0) == _interactionEpoch &&
          widget.gateCurrent?.call() == true &&
          identical(ModalRoute.of(context), _route) &&
          _route?.isCurrent == true &&
          TickerMode.valuesOf(context).enabled;
    } catch (_) {
      return false;
    }
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    if (!_interactiveCurrent(generation)) return;
    setState(() {
      _loading = true;
      _error = null;
      _hostsError = null;
      _providerError = false;
    });
    AndroidGameStreamCapabilities? capabilities;
    CoreGameStreamHosts? hosts;
    String? capabilityError;
    String? hostsError;
    try {
      capabilities = await _port.capabilities();
    } catch (_) {
      capabilityError = 'capability_read_failed';
    }
    if (!_interactiveCurrent(generation)) return;
    final account = ref.read(serverAccountControllerProvider);
    final session = account.session;
    if (account.initialized &&
        !account.working &&
        session?.context != null &&
        !session!.user.mustChangePassword) {
      if (_client != null || _clientRetirement != null) {
        await _retireClient();
        if (!_interactiveCurrent(generation)) return;
      }
      final transport = LarenorServerApi(endpoint: session.endpoint);
      final api = CoreGameStreamApi(
        transport,
        session,
        isCurrent: () =>
            identical(account.session, session) &&
            account.initialized &&
            !account.working,
      );
      try {
        if (capabilities?.available == true &&
            capabilities?.handoffOnly != true &&
            session.sessionFamilyId != null &&
            widget.gateAuthority?.call() != null) {
          _sessionOwner = session;
          bool current() =>
              _current(generation) &&
              identical(ref.read(serverAccountControllerProvider), account) &&
              identical(account.session, session);
          bool coverageCurrent() => _coverageCurrent(generation, session);
          final client =
              widget.clientFactory?.call(
                core: api,
                native: _v2Port,
                authority: _nativeAuthority,
                isCurrent: current,
                isCoverageCurrent: coverageCurrent,
              ) ??
              GameStreamClientController(
                core: api,
                native: _v2Port,
                authority: _nativeAuthority,
                isCurrent: current,
                isCoverageCurrent: coverageCurrent,
              );
          _client = client;
          _clientTransport = transport;
          client.addListener(_clientChanged);
          await client.initialize();
          if (!_interactiveCurrent(generation)) return;
          hosts = CoreGameStreamHosts(
            accountRevision: client.state.accountRevision ?? 1,
            hosts: client.state.hosts,
          );
        } else {
          hosts = await api.hosts();
        }
      } catch (_) {
        hostsError = 'host_read_failed';
      } finally {
        if (!identical(_client, null) &&
            identical(_clientTransport, transport)) {
          // The route-scoped controller owns this connection.
        } else {
          api.retire();
          transport.close();
        }
      }
    }
    if (!_interactiveCurrent(generation)) return;
    setState(() {
      _capabilities = capabilities;
      _hosts = hosts;
      _error = capabilityError;
      _hostsError = hostsError;
      _loading = false;
    });
  }

  Future<void> _openProvider() async {
    final provider = _port;
    if (provider is! GameStreamProviderPort ||
        _capabilities?.available != true ||
        _capabilities?.handoffOnly != true ||
        _openingProvider) {
      return;
    }
    final providerPort = provider as GameStreamProviderPort;
    final generation = _generation;
    if (!_interactiveCurrent(generation)) return;
    setState(() {
      _openingProvider = true;
      _providerError = false;
    });
    try {
      final launch = await providerPort.openProvider();
      if (!_interactiveCurrent(generation) ||
          launch.provider != _capabilities?.provider ||
          launch.engineRevision != _capabilities?.engineRevision ||
          !launch.handoffOnly) {
        return;
      }
    } catch (_) {
      if (_interactiveCurrent(generation)) _providerError = true;
    } finally {
      if (_interactiveCurrent(generation)) {
        setState(() => _openingProvider = false);
      }
    }
  }

  Future<void> _beginPairing() async {
    final client = _client;
    if (client == null || !_interactiveCurrent(_generation)) return;
    await client.beginPairing();
  }

  Future<void> _pair(AndroidGameStreamCandidate candidate) async {
    final client = _client;
    if (client == null || !_interactiveCurrent(_generation)) return;
    await client.pair(candidate);
  }

  Future<void> _selectHost(CoreGameStreamHost host) async {
    final client = _client;
    if (client == null || !_interactiveCurrent(_generation)) return;
    await client.selectHost(host);
  }

  Future<void> _selectApp(CoreGameStreamApp app) async {
    final client = _client;
    if (client == null || !_interactiveCurrent(_generation)) return;
    await client.selectApp(app);
  }

  Future<void> _refreshCatalog() async {
    final client = _client;
    if (client == null || !_interactiveCurrent(_generation)) return;
    await client.refreshCatalog();
  }

  Future<void> _configurePolicy() async {
    final client = _client;
    final host = client?.state.selectedHost;
    final draft = host == null
        ? null
        : client?.state.capabilities?.explicitPolicyDraft(host);
    if (client == null ||
        host == null ||
        draft == null ||
        !_interactiveCurrent(_generation)) {
      return;
    }
    final copy = _GameStreamCopy.of(context);
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(copy.configurePolicy),
        content: Text(
          copy.policyDetails(
            draft.allowedCodecs.join(', ').toUpperCase(),
            draft.maxWidth,
            draft.maxHeight,
            draft.maxFps,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(copy.cancel),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(copy.savePolicy),
          ),
        ],
      ),
    );
    if (accepted != true || !_interactiveCurrent(_generation)) return;
    await client.configurePolicy(draft);
    final app = client.state.selectedApp;
    if (app != null && _interactiveCurrent(_generation)) {
      await client.selectApp(app);
    }
  }

  Future<void> _revoke(CoreGameStreamHost host) async {
    final client = _client;
    if (client == null || !_interactiveCurrent(_generation)) return;
    final copy = _GameStreamCopy.of(context);
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(copy.forgetComputer),
        content: Text(copy.forgetComputerBody(host.name)),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(copy.cancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(copy.forgetComputer),
          ),
        ],
      ),
    );
    if (accepted == true && _interactiveCurrent(_generation)) {
      await client.revoke(host);
      if (!mounted ||
          !_interactiveCurrent(_generation) ||
          client.state.phase != GameStreamClientPhase.idle ||
          client.state.hosts.any((candidate) => candidate.id == host.id)) {
        return;
      }
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(copy.localRetirementComplete),
          content: Text(copy.localRetirementSuccess(host.name)),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.of(context).pop(),
              child: Text(copy.done),
            ),
          ],
        ),
      );
    }
  }

  @override
  void dispose() {
    widget.foregroundCoverageGuard?.detach(this);
    _interaction?.removeListener(_interactionChanged);
    _serverAccount.removeListener(_serverAccountChanged);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_retireClient());
    _generation += 1;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(serverAccountControllerProvider);
    final l10n = AppLocalizations.of(context);
    final copy = _GameStreamCopy.of(context);
    final clientState = _client?.state;
    final status = _loading
        ? l10n.gameStreamingChecking
        : _error != null
        ? l10n.gameStreamingError
        : _capabilities?.available == true
        ? _capabilities?.handoffOnly == true
              ? copy.handoffAvailable
              : l10n.gameStreamingAvailable
        : _capabilities != null
        ? l10n.gameStreamingUnavailable
        : l10n.gameStreamingNotChecked;
    final statusColor = _loading
        ? CupertinoColors.systemBlue
        : _error != null
        ? CupertinoColors.systemRed
        : _capabilities?.available == true
        ? _capabilities?.handoffOnly == true
              ? CupertinoColors.systemBlue
              : CupertinoColors.systemGreen
        : _capabilities != null
        ? CupertinoColors.systemOrange
        : CupertinoColors.secondaryLabel;
    final current = _interactiveCurrent(_generation);
    final clientReadyForEffect =
        current &&
        clientState?.busy != true &&
        clientState?.phase != GameStreamClientPhase.outcomeUnknown;
    final capabilities = _capabilities;
    final providerReady =
        current &&
        !_loading &&
        !_openingProvider &&
        capabilities?.available == true &&
        capabilities?.handoffOnly == true &&
        _port is GameStreamProviderPort;

    return SettingsPaneScaffold(
      title: l10n.gameStreamingTitle,
      children: [
        SettingsSection(
          header: Semantics(
            key: const ValueKey('game-stream-engine-header'),
            header: true,
            child: Text(l10n.gameStreamingEngineHeader),
          ),
          footer: Text(
            capabilities?.handoffOnly == true
                ? copy.handoffBoundary
                : capabilities?.available == true
                ? copy.embeddedFooter
                : l10n.gameStreamingDeferredBody,
          ),
          children: [
            Semantics(
              key: const ValueKey('game-stream-status'),
              container: true,
              liveRegion: true,
              label: '${l10n.gameStreamingEngineHeader}. $status',
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        _capabilities?.available == true
                            ? _capabilities?.handoffOnly == true
                                  ? CupertinoIcons.arrow_up_right_square
                                  : CupertinoIcons.checkmark_circle_fill
                            : CupertinoIcons.game_controller_solid,
                        color: statusColor.resolveFrom(context),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(status)),
                    ],
                  ),
                ),
              ),
            ),
            SettingsActionTile(
              buttonKey: const ValueKey('game-stream-refresh'),
              leading: const IconBadge(
                icon: CupertinoIcons.refresh,
                color: CupertinoColors.systemBlue,
              ),
              title: Text(l10n.gameStreamingCheckAgain),
              onTap: current && !_loading && clientState?.busy != true
                  ? () => unawaited(_refresh())
                  : null,
            ),
            if (capabilities?.handoffOnly == true)
              SettingsActionTile(
                buttonKey: const ValueKey('game-stream-open-provider'),
                leading: const IconBadge(
                  icon: CupertinoIcons.play_rectangle_fill,
                  color: CupertinoColors.systemPurple,
                ),
                title: Text(
                  _openingProvider ? copy.openingProvider : copy.openProvider,
                ),
                additionalInfo: Text(
                  '${copy.provider}: ${capabilities?.provider ?? copy.unknown}; '
                  '${copy.version}: ${capabilities?.engineRevision ?? copy.unknown}',
                ),
                onTap: providerReady ? () => unawaited(_openProvider()) : null,
              ),
            if (_providerError)
              Semantics(
                key: const ValueKey('game-stream-provider-error'),
                container: true,
                liveRegion: true,
                label: copy.providerLaunchFailed,
                child: ExcludeSemantics(
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      16,
                      10,
                      16,
                      14,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          CupertinoIcons.exclamationmark_circle_fill,
                          color: CupertinoColors.systemRed.resolveFrom(context),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            copy.providerLaunchFailed,
                            style: TextStyle(
                              color: CupertinoColors.systemRed.resolveFrom(
                                context,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        SettingsSection(
          header: Semantics(header: true, child: Text(copy.configuredHosts)),
          footer: Text(copy.hostsBoundary),
          children: [
            if (_client != null)
              SettingsActionTile(
                buttonKey: const ValueKey('game-stream-add-computer'),
                leading: const IconBadge(
                  icon: CupertinoIcons.add_circled_solid,
                  color: CupertinoColors.systemBlue,
                ),
                title: Text(copy.addComputer),
                additionalInfo: Text(copy.addComputerDetail),
                onTap: clientReadyForEffect
                    ? () => unawaited(_beginPairing())
                    : null,
              ),
            if (clientState?.candidates.isNotEmpty == true)
              for (final candidate in clientState!.candidates)
                SettingsActionTile(
                  buttonKey: ValueKey('game-stream-pair-${candidate.id}'),
                  leading: const IconBadge(
                    icon: CupertinoIcons.link,
                    color: CupertinoColors.systemPurple,
                  ),
                  title: Text(candidate.name),
                  additionalInfo: Text(
                    '${copy.power}: ${candidate.powerState} · '
                    '${copy.pairing}: ${candidate.pairState}',
                  ),
                  onTap: clientReadyForEffect
                      ? () => unawaited(_pair(candidate))
                      : null,
                ),
            if (_hostsError != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  copy.hostReadFailed,
                  style: const TextStyle(color: CupertinoColors.systemRed),
                ),
              )
            else if (_hosts == null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(copy.signInForHosts),
              )
            else if (_hosts!.hosts.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(copy.noHosts),
              )
            else
              for (final host in _hosts!.hosts)
                SettingsActionTile(
                  buttonKey: ValueKey('game-stream-host-${host.id}'),
                  leading: const IconBadge(
                    icon: CupertinoIcons.desktopcomputer,
                    color: CupertinoColors.systemPurple,
                  ),
                  title: Text(host.name),
                  additionalInfo: Text(
                    '${host.codecs.join(' · ')} · ${copy.nativeObserved}',
                  ),
                  onTap: clientReadyForEffect && _client != null
                      ? () => unawaited(_selectHost(host))
                      : null,
                ),
          ],
        ),
        if (clientState?.selectedHost != null)
          SettingsSection(
            header: Semantics(
              header: true,
              child: Text(copy.appCatalog(clientState!.selectedHost!.name)),
            ),
            footer: Text(copy.catalogBoundary),
            children: [
              SettingsActionTile(
                buttonKey: const ValueKey('game-stream-refresh-catalog'),
                leading: const IconBadge(
                  icon: CupertinoIcons.refresh_circled_solid,
                  color: CupertinoColors.systemBlue,
                ),
                title: Text(copy.refreshCatalog),
                additionalInfo: Text(copy.refreshCatalogDetail),
                onTap: clientReadyForEffect
                    ? () => unawaited(_refreshCatalog())
                    : null,
              ),
              if (clientState.apps.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(copy.noApps),
                )
              else
                for (final app in clientState.apps)
                  SettingsActionTile(
                    buttonKey: ValueKey('game-stream-app-${app.id}'),
                    leading: IconBadge(
                      icon: clientState.selectedApp?.id == app.id
                          ? CupertinoIcons.checkmark_circle_fill
                          : CupertinoIcons.game_controller_solid,
                      color: CupertinoColors.systemIndigo,
                    ),
                    title: Text(app.name),
                    additionalInfo: Text(copy.nativeObserved),
                    onTap: clientReadyForEffect
                        ? () => unawaited(_selectApp(app))
                        : null,
                  ),
              if (clientState.selectedApp != null)
                SettingsActionTile(
                  buttonKey: const ValueKey('game-stream-configure-policy'),
                  leading: const IconBadge(
                    icon: CupertinoIcons.slider_horizontal_3,
                    color: CupertinoColors.systemBlue,
                  ),
                  title: Text(copy.configurePolicy),
                  additionalInfo: Text(copy.configurePolicyDetail),
                  onTap:
                      clientReadyForEffect &&
                          _policyDraft(
                                clientState.selectedHost!,
                                clientState.capabilities,
                              ) !=
                              null
                      ? () => unawaited(_configurePolicy())
                      : null,
                ),
            ],
          ),
        if (clientState?.selectedApp != null)
          SettingsSection(
            header: Semantics(header: true, child: Text(copy.quality)),
            footer: Text(
              clientState!.capabilities?.available == true
                  ? copy.qualityBoundary
                  : copy.qualityUnavailable(
                      clientState.capabilities?.reason ?? copy.unknown,
                    ),
            ),
            children: [
              for (final option
                  in clientState.capabilities?.qualityOptions ??
                      const <AndroidGameStreamQualityOption>[])
                SettingsActionTile(
                  buttonKey: ValueKey(
                    'game-stream-quality-${option.codecId}-'
                    '${option.widthPixels}-${option.framesPerSecond}',
                  ),
                  leading: IconBadge(
                    icon: identical(clientState.selectedQuality, option)
                        ? CupertinoIcons.checkmark_circle_fill
                        : CupertinoIcons.circle,
                    color: CupertinoColors.systemGreen,
                  ),
                  title: Text(
                    '${option.widthPixels}×${option.heightPixels} · '
                    '${option.framesPerSecond} FPS',
                  ),
                  additionalInfo: Text(
                    '${option.selectedQuality.codec.toUpperCase()} · '
                    '${option.bitrateKbps} kbps',
                  ),
                  onTap: clientReadyForEffect
                      ? () => _client?.chooseQuality(option)
                      : null,
                ),
              if (clientState.selectedQuality != null &&
                  clientState.phase != GameStreamClientPhase.streaming)
                SettingsActionTile(
                  buttonKey: const ValueKey('game-stream-start'),
                  leading: const IconBadge(
                    icon: CupertinoIcons.play_fill,
                    color: CupertinoColors.systemGreen,
                  ),
                  title: Text(copy.startStream),
                  additionalInfo: Text(copy.startBoundary),
                  onTap: clientReadyForEffect
                      ? () => unawaited(_client!.start())
                      : null,
                ),
              if (clientState.errorCode != null)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      copy.operationError(clientState.errorCode!),
                      style: const TextStyle(color: CupertinoColors.systemRed),
                    ),
                  ),
                ),
              SettingsActionTile(
                buttonKey: const ValueKey('game-stream-revoke'),
                leading: const IconBadge(
                  icon: CupertinoIcons.trash_fill,
                  color: CupertinoColors.systemRed,
                ),
                title: Text(copy.forgetComputer),
                onTap: clientReadyForEffect && clientState.activeSession == null
                    ? () => unawaited(_revoke(clientState.selectedHost!))
                    : null,
              ),
            ],
          ),
        if (clientState != null &&
            (clientState.phase == GameStreamClientPhase.streaming ||
                (clientState.phase == GameStreamClientPhase.outcomeUnknown &&
                    clientState.activeSession != null)))
          SettingsSection(
            children: [
              GameStreamSessionLifecycleAction(
                phase: clientState.phase,
                hasActiveSession: clientState.activeSession != null,
                enabled: current && clientState.busy != true,
                onStop: () => unawaited(_client!.stop()),
                onCloseLocalSession: () =>
                    unawaited(_client!.closeLocalSession()),
              ),
            ],
          ),
        SettingsSection(
          header: Semantics(
            key: const ValueKey('game-stream-boundary-header'),
            header: true,
            child: Text(l10n.gameStreamingBoundaryHeader),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                capabilities?.handoffOnly == true
                    ? copy.handoffBoundary
                    : l10n.gameStreamingBoundaryBody,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

@visibleForTesting
final class GameStreamSessionLifecycleAction extends StatelessWidget {
  const GameStreamSessionLifecycleAction({
    super.key,
    required this.phase,
    required this.hasActiveSession,
    required this.enabled,
    required this.onStop,
    required this.onCloseLocalSession,
  });

  final GameStreamClientPhase phase;
  final bool hasActiveSession;
  final bool enabled;
  final VoidCallback onStop;
  final VoidCallback onCloseLocalSession;

  @override
  Widget build(BuildContext context) {
    final copy = _GameStreamCopy.of(context);
    if (phase == GameStreamClientPhase.streaming) {
      return SettingsActionTile(
        buttonKey: const ValueKey('game-stream-stop'),
        leading: const IconBadge(
          icon: CupertinoIcons.stop_fill,
          color: CupertinoColors.systemRed,
        ),
        title: Text(copy.stopStream),
        additionalInfo: Text(copy.stopBoundary),
        onTap: enabled ? onStop : null,
      );
    }
    if (phase == GameStreamClientPhase.outcomeUnknown && hasActiveSession) {
      return SettingsActionTile(
        buttonKey: const ValueKey('game-stream-close-local-session'),
        leading: const IconBadge(
          icon: CupertinoIcons.clear_circled_solid,
          color: CupertinoColors.systemOrange,
        ),
        title: Text(copy.closeLocalSession),
        additionalInfo: Text(copy.closeLocalSessionBoundary),
        onTap: enabled ? onCloseLocalSession : null,
      );
    }
    return const SizedBox.shrink();
  }
}

String _newClientInstanceId() {
  final random = Random.secure();
  return List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

final class _GameStreamCopy {
  const _GameStreamCopy({
    required this.openProvider,
    required this.openingProvider,
    required this.provider,
    required this.version,
    required this.unknown,
    required this.handoffBoundary,
    required this.embeddedFooter,
    required this.handoffAvailable,
    required this.configuredHosts,
    required this.hostsBoundary,
    required this.hostReadFailed,
    required this.signInForHosts,
    required this.noHosts,
    required this.providerLaunchFailed,
    required this.addComputer,
    required this.addComputerDetail,
    required this.power,
    required this.pairing,
    required this.nativeObserved,
    required this.noApps,
    required this.catalogBoundary,
    required this.refreshCatalog,
    required this.refreshCatalogDetail,
    required this.configurePolicy,
    required this.configurePolicyDetail,
    required this.cancel,
    required this.done,
    required this.savePolicy,
    required this.forgetComputer,
    required this.localRetirementComplete,
    required this.quality,
    required this.qualityBoundary,
    required this.startStream,
    required this.startBoundary,
    required this.stopStream,
    required this.stopBoundary,
    required this.unknownNoReplay,
    required this.closeLocalSession,
    required this.closeLocalSessionBoundary,
    required this.appCatalogTemplate,
    required this.policyDetailsTemplate,
    required this.forgetComputerBodyTemplate,
    required this.localRetirementSuccessTemplate,
    required this.qualityUnavailableTemplate,
    required this.operationErrorTemplate,
    required this.pinRequired,
  });

  final String openProvider;
  final String openingProvider;
  final String provider;
  final String version;
  final String unknown;
  final String handoffBoundary;
  final String embeddedFooter;
  final String handoffAvailable;
  final String configuredHosts;
  final String hostsBoundary;
  final String hostReadFailed;
  final String signInForHosts;
  final String noHosts;
  final String providerLaunchFailed;
  final String addComputer, addComputerDetail, power, pairing, nativeObserved;
  final String noApps, catalogBoundary, refreshCatalog;
  final String refreshCatalogDetail, configurePolicy;
  final String configurePolicyDetail, cancel, done, savePolicy, forgetComputer;
  final String localRetirementComplete;
  final String quality, qualityBoundary, startStream, startBoundary;
  final String stopStream, stopBoundary, unknownNoReplay;
  final String closeLocalSession, closeLocalSessionBoundary;
  final String appCatalogTemplate, policyDetailsTemplate;
  final String forgetComputerBodyTemplate, localRetirementSuccessTemplate;
  final String qualityUnavailableTemplate;
  final String operationErrorTemplate;
  final String pinRequired;

  String appCatalog(String host) =>
      appCatalogTemplate.replaceAll('{host}', host);
  String policyDetails(String codecs, int width, int height, int fps) =>
      policyDetailsTemplate
          .replaceAll('{codecs}', codecs)
          .replaceAll('{width}', '$width')
          .replaceAll('{height}', '$height')
          .replaceAll('{fps}', '$fps');
  String forgetComputerBody(String host) =>
      forgetComputerBodyTemplate.replaceAll('{host}', host);
  String localRetirementSuccess(String host) =>
      localRetirementSuccessTemplate.replaceAll('{host}', host);
  String qualityUnavailable(String reason) =>
      qualityUnavailableTemplate.replaceAll('{reason}', reason);
  String operationError(String code) => code == 'pin_required'
      ? pinRequired
      : operationErrorTemplate.replaceAll('{code}', code);

  static _GameStreamCopy of(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'tr' ? tr : en;

  static const tr = _GameStreamCopy(
    openProvider: 'Moonlight uygulamasını aç',
    openingProvider: 'Moonlight açılıyor…',
    provider: 'Sağlayıcı',
    version: 'Sürüm',
    unknown: 'bilinmiyor',
    handoffAvailable:
        'Moonlight kurulu; eşleme ve oynatma Moonlight içinde açılır.',
    handoffBoundary:
        'Larenor yalnız kurulu Moonlight istemcisini doğrular ve açar. '
        'Eşleme, yayın, görüntü, ses ve giriş yaşam döngüsü Moonlight tarafından yönetilir; '
        'Larenor harici yayının başladığını veya durduğunu iddia etmez.',
    embeddedFooter:
        'Bilgisayarını eşleştir, desteklenen yayını seç ve bu tablette aç. '
        'Görüntü ve giriş desteği bilgisayarına ve tabletine bağlıdır.',
    configuredHosts: 'Yapılandırılmış Sunshine bilgisayarları',
    hostsBoundary:
        'Bu liste Core üzerindeki sürüm sabitli, gizli bilgi içermeyen host kayıtlarıdır. '
        'Canlı erişilebilirlik ve fiziksel yayın ayrıca doğrulanır.',
    hostReadFailed: 'Bilgisayar kayıtları Core’dan okunamadı.',
    signInForHosts:
        'Bilgisayarları görmek için geçerli bir Core oturumu gerekir.',
    noHosts: 'Henüz yapılandırılmış bir oyun bilgisayarı yok.',
    providerLaunchFailed: 'Moonlight açılamadı. Uygulamanın kurulu ve kullanılabilir olduğunu denetleyip tekrar deneyin.',
    addComputer: 'Sunshine bilgisayarı ekle',
    addComputerDetail: 'Bilgisayarını bulmak ve eşleme izni istemek için yerel ağ keşfini başlat.',
    power: 'Güç',
    pairing: 'Eşleme',
    nativeObserved: 'Android tarafından gözlendi',
    noApps: 'Bu bilgisayar için kullanılabilir uygulama gözlenmedi.',
    catalogBoundary: 'Uygulamalar Android Moonlight motorunun gözlemlediği, Core kimliklerine bağlanmış katalogdan gelir.',
    refreshCatalog: 'Uygulama kataloğunu yenile',
    refreshCatalogDetail: 'Core tek kullanımlık izin verdikten sonra Android kataloğunu bir kez oku.',
    configurePolicy: 'Yayın politikasını ayarla',
    configurePolicyDetail:
        'Kalite sınırlarını ve izin verilen kodekleri açıkça kaydet.',
    cancel: 'Vazgeç',
    done: 'Tamam',
    savePolicy: 'Politikayı kaydet',
    forgetComputer: 'Bu tabletten kaldır',
    localRetirementComplete: 'Yerel erişim kaldırıldı',
    quality: 'Yayın kalitesi',
    qualityBoundary: 'Seçenekler ekran, ağ, çözücü, host ve açık politika kesişiminden gelir.',
    startStream: 'Yayını başlat',
    startBoundary: 'Seçilen uygulamayı bu tablette açmadan önce izin istenir.',
    stopStream: 'Yayını durdur',
    stopBoundary: 'Mevcut Core oturumu için açık durdurma komutu gönderilir.',
    unknownNoReplay: 'Sonuç bilinmiyor. Otomatik yeniden gönderim yapılmaz.',
    closeLocalSession: 'Yerel oturumu kapat',
    closeLocalSessionBoundary: 'Yeni bir durdurma komutu göndermeden yalnız bu tabletteki yerel oturumu ve Core kiralamasını kapatmayı dener. Sağlayıcının durduğu veya eşlemenin kaldırıldığı iddia edilmez.',
    appCatalogTemplate: '{host} uygulamaları',
    policyDetailsTemplate: '{codecs} · yerel ekran/çözücü sınırı {width}×{height} · {fps} FPS · ölçülü ağ kapalı · 60 dakika sınırı.',
    forgetComputerBodyTemplate:
        '{host} bilgisayarına Larenor Core erişimini ve bu tabletin gizli kaydını kaldır. '
        'Bilgisayar Sunshine içinde eşlenmiş olarak kalır. Bilgisayarın bu tablete verdiği güveni kaldırmak için '
        'bu istemciyi Sunshine ayarlarından ayrıca sil. Yerel sonuç bilinmezse Larenor kaydı karantinada tutar ve otomatik yeniden denemez.',
    localRetirementSuccessTemplate:
        '{host}, Larenor ve bu tabletten kaldırıldı. Sunshine eşlemesi korunuyor. '
        'Bilgisayarın güvenini kaldırmak için bu istemciyi Sunshine ayarlarından sil.',
    qualityUnavailableTemplate:
        'Gerçek kalite gözlemi kullanılamıyor: {reason}.',
    operationErrorTemplate: 'İşlem tamamlanamadı ({code}).',
    pinRequired: 'Yayın için Ayarlar PIN’i oluşturun ve bu ayarlar oturumunda kilidi açın.',
  );

  static const en = _GameStreamCopy(
    openProvider: 'Open Moonlight',
    openingProvider: 'Opening Moonlight…',
    provider: 'Provider',
    version: 'Version',
    unknown: 'unknown',
    handoffAvailable:
        'Moonlight is installed; pairing and playback open in Moonlight.',
    handoffBoundary:
        'Larenor only verifies and opens the installed Moonlight client. '
        'Moonlight owns pairing, streaming, video, audio and input lifecycle; '
        'Larenor does not claim that an external stream started or stopped.',
    embeddedFooter:
        'Pair your computer, choose a supported stream, and open it on this tablet. '
        'Video and input support depend on your computer and tablet.',
    configuredHosts: 'Configured Sunshine computers',
    hostsBoundary:
        'This list contains revision-bound, secret-free host records from Core. '
        'Live reachability and physical streaming require separate verification.',
    hostReadFailed: 'Computer records could not be read from Core.',
    signInForHosts: 'A current Core session is required to show computers.',
    noHosts: 'No game computer has been configured yet.',
    providerLaunchFailed: 'Moonlight could not be opened. Check that the app is installed and available, then try again.',
    addComputer: 'Add Sunshine computer',
    addComputerDetail: 'Start local network discovery to find your computer and request pairing.',
    power: 'Power',
    pairing: 'Pairing',
    nativeObserved: 'Observed by Android',
    noApps: 'No available application was observed for this computer.',
    catalogBoundary: 'Applications come from the Android Moonlight engine catalog bound to Core identities.',
    refreshCatalog: 'Refresh application catalog',
    refreshCatalogDetail:
        'Read the Android catalog once after Core issues a one-use grant.',
    configurePolicy: 'Configure streaming policy',
    configurePolicyDetail: 'Explicitly save quality limits and allowed codecs.',
    cancel: 'Cancel',
    done: 'Done',
    savePolicy: 'Save policy',
    forgetComputer: 'Remove from this tablet',
    localRetirementComplete: 'Local access removed',
    quality: 'Streaming quality',
    qualityBoundary: 'Options are the intersection of the display, network, decoder, host and explicit policy.',
    startStream: 'Start stream',
    startBoundary: 'Authorization is requested before opening the selected application on this tablet.',
    stopStream: 'Stop stream',
    stopBoundary:
        'Sends an explicit stop command for the current Core session.',
    unknownNoReplay: 'The outcome is unknown. The command will not be sent again automatically.',
    closeLocalSession: 'Close local session',
    closeLocalSessionBoundary: 'Attempts to retire only this tablet\'s local session and Core lease without sending another stop command. This does not claim that the provider stopped or that pairing was removed.',
    appCatalogTemplate: '{host} applications',
    policyDetailsTemplate: '{codecs} · local display/decoder ceiling {width}×{height} · {fps} FPS · metered network off · 60 minute limit.',
    forgetComputerBodyTemplate:
        'Remove Larenor Core access to {host} and this tablet\'s private registration. '
        'The computer remains paired in Sunshine. To revoke the computer\'s trust in this tablet, '
        'remove this client separately in Sunshine settings. If the local outcome is uncertain, Larenor quarantines the record and does not retry automatically.',
    localRetirementSuccessTemplate:
        '{host} was removed from Larenor and this tablet. Its Sunshine pairing remains. '
        'Remove this client in Sunshine settings to revoke the computer\'s trust.',
    qualityUnavailableTemplate:
        'A real quality observation is unavailable: {reason}.',
    operationErrorTemplate: 'The operation could not be completed ({code}).',
    pinRequired: 'Set a Settings PIN and unlock it in this settings session before streaming.',
  );
}

AndroidGameStreamPolicyDraft? _policyDraft(
  CoreGameStreamHost host,
  AndroidGameStreamSessionCapabilities? capabilities,
) => capabilities?.explicitPolicyDraft(host);
