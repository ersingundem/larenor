import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../settings/providers/settings_providers.dart';
import '../../data/server_account_controller.dart';
import '../../music_provider_commands/presentation/server_music_provider_commands_screen.dart';
import '../../providers/server_providers.dart';
import '../data/server_music_retained_controller.dart';
import '../domain/server_music_retained_models.dart';

class ServerMusicRetainedScreen extends ConsumerStatefulWidget {
  const ServerMusicRetainedScreen({super.key});

  @override
  ConsumerState<ServerMusicRetainedScreen> createState() =>
      _ServerMusicRetainedScreenState();
}

class _ServerMusicRetainedScreenState
    extends ConsumerState<ServerMusicRetainedScreen>
    with WidgetsBindingObserver {
  late final ServerAccountController _account;
  late final ServerMusicRetainedController _status;
  late final int _accountEpoch;
  ValueListenable<TickerModeData>? _ticker;
  int _lifecycle = 0;
  bool _visible = true, _loaded = false, _expired = false, _pinReady = false;

  bool get _active =>
      mounted &&
      !_expired &&
      _visible &&
      _pinReady &&
      _account.isCurrent(_accountEpoch) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    _status = ServerMusicRetainedController(_account);
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
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _expire();
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountEpoch) ||
        _account.session?.user.canAdminister != true) {
      _expire();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _expire();
  }

  void _expire() {
    if (_expired) return;
    final wasBusy = _status.busy;
    _expired = true;
    _lifecycle++;
    _status.invalidate();
    if (wasBusy && !_account.working) unawaited(_account.cancelPending());
  }

  bool Function() _capture() {
    final lifecycle = _lifecycle;
    return () => _active && lifecycle == _lifecycle;
  }

  void _load() {
    final current = _capture();
    if (current()) unawaited(_status.load(current: current));
  }

  Future<void> _openProviderCommands(
    ServerMusicRetainedInstallation installation,
    ServerMusicProviderStatus provider,
  ) async {
    if (!_active || provider.state != 'ready') return;
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => ServerMusicProviderCommandsScreen(
          target: ServerMusicProviderCommandTarget(
            installationId: installation.installationId,
            installationRevision: installation.installationRevision,
            providerSetupId: provider.id,
            providerRevision: provider.revision,
            providerDomain: provider.domain,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _status.dispose();
    super.dispose();
  }

  String _state(AppLocalizations l, String state) => switch (state) {
    'unknown' => l.serverMusicRetainedUnknown,
    'partial' => l.serverMusicRetainedPartial,
    'failed' => l.serverMusicRetainedFailed,
    _ => l.serverMusicRetainedReady,
  };

  String _provider(String domain) => switch (domain) {
    'spotify' => 'Spotify',
    'apple_music' => 'Apple Music',
    _ => 'YouTube Music',
  };

  String _installationState(AppLocalizations l, String state) =>
      switch (state) {
        'queued' || 'running' => l.serverMusicRetainedPending,
        'container_started' => l.serverMusicRetainedContainerReady,
        'needs_attention' => l.serverMusicRetainedPartial,
        'cancelled' => l.serverMusicRetainedCancelled,
        _ => l.serverMusicRetainedFailed,
      };

  String _error(AppLocalizations l, String code) => switch (code) {
    'installation_pending' => l.serverMusicRetainedInstallationPending,
    'installation_failed' => l.serverMusicRetainedInstallationFailed,
    'bootstrap_unknown' => l.serverMusicRetainedBootstrapUnknown,
    'installation_changed' => l.serverMusicRetainedInstallationChanged,
    'dependency_changed' => l.serverMusicRetainedDependencyChanged,
    'provider_not_ready' => l.serverMusicRetainedProviderNotReady,
    _ => l.serverMusicRetainedProviderFailed,
  };

  String _providerState(AppLocalizations l, String state) => switch (state) {
    'queued' => l.serverMusicRetainedPending,
    'ready' => l.serverMusicRetainedReady,
    'cancelled' => l.serverMusicRetainedCancelled,
    'action_required' || 'needs_attention' => l.serverMusicRetainedPartial,
    _ => l.serverMusicRetainedFailed,
  };

  Widget _installation(
    AppLocalizations l,
    ServerMusicRetainedInstallation item,
  ) => SettingsSection(
    header: Semantics(
      header: true,
      child: Text(l.serverMusicRetainedInstallation),
    ),
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(_state(l, item.state), style: AppText.headline),
            ),
            const SizedBox(height: 8),
            Text(item.installationId, style: AppText.footnote),
            Text(
              '${l.serverMusicRetainedRevision}: '
              '${item.installationRevision}',
            ),
            Text(_installationState(l, item.installationState)),
            if (item.errorCode != null) Text(_error(l, item.errorCode!)),
            if (item.bootstrap case final receipt?) ...[
              const SizedBox(height: 16),
              Semantics(
                header: true,
                child: Text(
                  l.serverMusicRetainedBootstrap,
                  style: AppText.subhead,
                ),
              ),
              Text(
                '${receipt.serverVersion} · schema ${receipt.schemaVersion}',
              ),
              Text(
                '${l.serverMusicRetainedHomeAssistant}: '
                '${receipt.homeAssistant.serviceId} · '
                '${l.serverMusicRetainedRevision} '
                '${receipt.homeAssistant.serviceRevision}',
              ),
              Text(
                '${l.serverMusicRetainedJellyfin}: '
                '${receipt.jellyfin.serviceId} · '
                '${l.serverMusicRetainedRevision} '
                '${receipt.jellyfin.serviceRevision}',
              ),
            ],
            const SizedBox(height: 16),
            Semantics(
              header: true,
              child: Text(
                l.serverMusicRetainedProviders,
                style: AppText.subhead,
              ),
            ),
            if (item.providers.isEmpty)
              Text(l.serverMusicRetainedNoProviders)
            else
              for (final provider in item.providers)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${_provider(provider.domain)} · '
                        '${_providerState(l, provider.state)} · '
                        '${l.serverMusicRetainedRevision} '
                        '${provider.revision}',
                      ),
                      Text(provider.id, style: AppText.footnote),
                      if (provider.state == 'ready')
                        CupertinoButton(
                          key: ValueKey(
                            'music-provider-command-${provider.id}',
                          ),
                          minimumSize: const Size(48, 48),
                          onPressed: _active
                              ? () => unawaited(
                                  _openProviderCommands(item, provider),
                                )
                              : null,
                          child: Text(l.serverMusicProviderCommandTitle),
                        ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    ],
  );

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
          l.serverMusicRetainedTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _status,
          builder: (context, _) {
            if (!_active) {
              return Center(child: Text(l.serverMusicRetainedAdminOnly));
            }
            final overview = _status.overview;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(l.serverMusicRetainedIntro),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: CupertinoButton(
                        key: const ValueKey('music-retained-refresh'),
                        minimumSize: const Size(48, 48),
                        onPressed: _status.busy ? null : _load,
                        child: Text(l.serverMusicRetainedRefresh),
                      ),
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
                          child: Text(l.serverMusicRetainedUnavailable),
                        ),
                      ),
                    if (overview != null) ...[
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _state(l, overview.state),
                            style: AppText.headline,
                          ),
                        ),
                      ),
                      for (final item in overview.installations)
                        _installation(l, item),
                    ],
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
