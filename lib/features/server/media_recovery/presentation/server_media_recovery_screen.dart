import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../settings/providers/settings_providers.dart';
import '../../data/server_account_controller.dart';
import '../../media_preparations/presentation/server_media_preparations_screen.dart';
import '../../music_retained/presentation/server_music_retained_screen.dart';
import '../../providers/server_providers.dart';
import '../data/server_media_recovery_controller.dart';
import '../domain/server_media_recovery_models.dart';

class ServerMediaRecoveryScreen extends ConsumerStatefulWidget {
  const ServerMediaRecoveryScreen({super.key});

  @override
  ConsumerState<ServerMediaRecoveryScreen> createState() =>
      _ServerMediaRecoveryScreenState();
}

class _ServerMediaRecoveryScreenState
    extends ConsumerState<ServerMediaRecoveryScreen>
    with WidgetsBindingObserver {
  late final ServerAccountController _account;
  late final ServerMediaRecoveryController _status;
  late final int _accountGeneration;
  ValueListenable<TickerModeData>? _ticker;
  int _lifecycle = 0;
  bool _visible = true, _appActive = true, _loaded = false;
  bool _expired = false, _pinReady = false;

  bool get _active =>
      mounted &&
      !_expired &&
      _visible &&
      _appActive &&
      _pinReady &&
      _account.isCurrent(_accountGeneration) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _account = ref.read(serverAccountControllerProvider);
    _accountGeneration = _account.generation;
    _status = ServerMediaRecoveryController(_account);
    _account.addListener(_accountChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticker = TickerMode.getValuesNotifier(context);
    if (!identical(ticker, _ticker)) {
      _ticker?.removeListener(_visibilityChanged);
      _ticker = ticker;
      _visible = ticker.value.enabled;
      ticker.addListener(_visibilityChanged);
    }
  }

  void _visibilityChanged() {
    final visible = _ticker?.value.enabled ?? true;
    if (_visible == visible) return;
    _visible = visible;
    if (visible) {
      _resume();
    } else {
      _suspend();
    }
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountGeneration) ||
        _account.session?.user.canAdminister != true) {
      _expire();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (_appActive == active) return;
    _appActive = active;
    if (active) {
      _resume();
    } else {
      _suspend();
    }
  }

  void _invalidatePending() {
    final wasBusy = _status.busy;
    _lifecycle++;
    _loaded = false;
    _status.invalidate();
    if (wasBusy && !_account.working) unawaited(_account.cancelPending());
  }

  void _suspend() => _invalidatePending();

  void _resume() {
    if (!mounted || _expired || !_visible || !_appActive) return;
    setState(() => _loaded = false);
  }

  void _expire() {
    if (_expired) return;
    _expired = true;
    _invalidatePending();
  }

  bool Function() _capture() {
    final lifecycle = _lifecycle;
    return () => _active && lifecycle == _lifecycle;
  }

  void _load() {
    final current = _capture();
    if (current()) unawaited(_status.load(current: current));
  }

  Future<void> _open(Widget screen) async {
    final current = _capture();
    if (!current()) return;
    await Navigator.of(context)
        .push<void>(CupertinoPageRoute(builder: (_) => screen));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _status.dispose();
    super.dispose();
  }

  String _service(AppLocalizations l, String value) => switch (value) {
    'larenor_core' => l.serverRecoveryCore,
    'qbittorrent' => 'qBittorrent',
    'sonarr' => 'Sonarr',
    'radarr' => 'Radarr',
    'jellyfin' => 'Jellyfin',
    'seerr' => 'Seerr',
    _ => 'Music Assistant',
  };

  String _stored(AppLocalizations l, String value) =>
      value == 'stored' ? l.serverRecoveryStored : l.serverRecoveryNotStored;
  String _process(AppLocalizations l, String value) => switch (value) {
    'started' => l.serverRecoveryProcessStarted,
    'pending' => l.serverRecoveryProcessPending,
    _ => l.serverRecoveryProcessUnknown,
  };
  String _integration(AppLocalizations l, String value) => value == 'verified'
      ? l.serverRecoveryIntegrationVerified
      : l.serverRecoveryIntegrationUnverified;
  String _reachable(AppLocalizations l, String value) => switch (value) {
    'reachable' => l.serverRecoveryReachable,
    'unreachable' => l.serverRecoveryUnreachable,
    _ => l.serverRecoveryReachabilityUnknown,
  };
  Widget _component(AppLocalizations l, ServerMediaRecoveryService item) {
    final name = _service(l, item.serviceId);
    final state =
        '${_stored(l, item.storedState)}. '
        '${_process(l, item.containerState)}. '
        '${_reachable(l, item.reachableState)}. '
        '${_integration(l, item.serviceState)}.';
    final observed = item.updatedAt == null
        ? null
        : '${l.serverRecoveryObservedAt}: '
              '${DateFormat.yMd(l.localeName).add_Hm().format(item.updatedAt!.toLocal())}';
    return Semantics(
      key: ValueKey('server-recovery-${item.serviceId}'),
      container: true,
      label: '$name. $state${observed == null ? '' : ' $observed'}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Icon(
                  item.verifiedState == 'verified'
                      ? CupertinoIcons.check_mark_circled_solid
                      : item.storedState == 'missing'
                      ? CupertinoIcons.circle
                      : CupertinoIcons.exclamationmark_circle,
                  color: item.verifiedState == 'verified'
                      ? CupertinoColors.systemGreen.resolveFrom(context)
                      : CupertinoColors.systemOrange.resolveFrom(context),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: AppText.headline),
                    const SizedBox(height: 4),
                    Text(state, style: AppText.footnote),
                    if (item.revision case final revision?)
                      Text(
                        '${l.serverRecoveryRevision} $revision',
                        style: AppText.footnote,
                      ),
                    if (observed != null)
                      Text(observed, style: AppText.footnote),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final pin = ref.watch(pinLockProvider);
    _pinReady = !pin.isLoading && !pin.hasError;
    ref.listen(pinLockProvider, (previous, next) {
      if (next.isLoading ||
          next.hasError ||
          (previous?.hasValue == true && previous?.value != next.value)) {
        _expire();
      }
    });
    if (_active && !_loaded) {
      _loaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_active) _load();
      });
    }
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          l.serverRecoveryTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _status,
          builder: (context, _) {
            if (!_active) {
              return Center(child: Text(l.serverRecoveryAdminOnly));
            }
            final status = _status.status;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(l.serverRecoveryIntro),
                    ),
                    SettingsSection(
                      header: Text(l.serverRecoveryActions),
                      footer: Text(l.serverRecoverySettingsHelp),
                      children: [
                        SettingsActionTile(
                          buttonKey: const ValueKey('server-recovery-refresh'),
                          leading: const Icon(CupertinoIcons.refresh),
                          title: Text(l.commonRefresh),
                          onTap: _status.busy ? null : _load,
                        ),
                        SettingsActionTile(
                          buttonKey: const ValueKey('server-recovery-operator'),
                          leading: const Icon(
                            CupertinoIcons.slider_horizontal_3,
                          ),
                          title: Text(l.serverRecoveryOperatorSettings),
                          additionalInfo: Text(
                            l.serverRecoveryOperatorSettingsDetail,
                          ),
                          onTap: _status.busy
                              ? null
                              : () => unawaited(
                                  _open(const ServerMediaPreparationsScreen()),
                                ),
                        ),
                        SettingsActionTile(
                          buttonKey: const ValueKey(
                            'server-recovery-providers',
                          ),
                          leading: const Icon(CupertinoIcons.music_note_2),
                          title: Text(l.serverRecoveryProviderAccounts),
                          additionalInfo: Text(
                            l.serverRecoveryProviderAccountsDetail,
                          ),
                          onTap: _status.busy
                              ? null
                              : () => unawaited(
                                  _open(const ServerMusicRetainedScreen()),
                                ),
                        ),
                      ],
                    ),
                    if (_status.busy)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: CupertinoActivityIndicator(),
                      ),
                    if (_status.failure != null)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(l.serverRecoveryUnavailable),
                        ),
                      ),
                    if (status != null)
                      SettingsSection(
                        header: Semantics(
                          key: const ValueKey('server-recovery-status-heading'),
                          header: true,
                          liveRegion: true,
                          child: Text(
                            status.state == 'ready'
                                ? l.serverRecoveryReady
                                : status.state == 'attention'
                                ? l.serverRecoveryAttention
                                : l.serverRecoveryIncomplete,
                          ),
                        ),
                        footer: Text(l.serverRecoveryEvidenceHelp),
                        children: [
                          for (final item in status.services)
                            _component(l, item),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
