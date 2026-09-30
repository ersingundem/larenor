import 'dart:async';
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
import '../../server/providers/server_providers.dart';
import '../data/android_game_stream_port.dart';
import '../data/core_game_stream_api.dart';

class GameStreamSettingsScreen extends ConsumerStatefulWidget {
  const GameStreamSettingsScreen({super.key, this.port, this.gateCurrent});

  final GameStreamCapabilityPort? port;
  final bool Function()? gateCurrent;

  @override
  ConsumerState<GameStreamSettingsScreen> createState() =>
      _GameStreamSettingsScreenState();
}

class _GameStreamSettingsScreenState
    extends ConsumerState<GameStreamSettingsScreen>
    with WidgetsBindingObserver {
  late final GameStreamCapabilityPort _port;
  AppInteractionController? _interaction;
  ModalRoute<dynamic>? _route;
  int _generation = 0;
  int _interactionEpoch = 0;
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

  @override
  void initState() {
    super.initState();
    _port = widget.port ?? AndroidGameStreamPort();
    WidgetsBinding.instance.addObserver(this);
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
    _invalidate(clearStatus: true);
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (!_resumed) _invalidate(clearStatus: true);
    if (mounted) setState(() {});
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (!mounted || event.viewId != View.of(context).viewId) return;
    _focused = event.state == ViewFocusState.focused;
    if (!_focused) _invalidate(clearStatus: true);
    setState(() {});
  }

  void _invalidate({required bool clearStatus}) {
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
    }
  }

  bool _current(int generation) {
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
    if (!_current(generation)) return;
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
    if (!_current(generation)) return;
    final account = ref.read(serverAccountControllerProvider);
    final session = account.session;
    if (account.initialized &&
        !account.working &&
        session?.context != null &&
        !session!.user.mustChangePassword) {
      final transport = LarenorServerApi(endpoint: session.endpoint);
      final api = CoreGameStreamApi(
        transport,
        session,
        isCurrent: () =>
            _current(generation) &&
            identical(ref.read(serverAccountControllerProvider), account) &&
            identical(account.session, session),
      );
      try {
        hosts = await api.hosts();
      } catch (_) {
        hostsError = 'host_read_failed';
      } finally {
        api.retire();
        transport.close();
      }
    }
    if (!_current(generation)) return;
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
    if (!_current(generation)) return;
    setState(() {
      _openingProvider = true;
      _providerError = false;
    });
    try {
      final launch = await providerPort.openProvider();
      if (!_current(generation) ||
          launch.provider != _capabilities?.provider ||
          launch.engineRevision != _capabilities?.engineRevision ||
          !launch.handoffOnly) {
        return;
      }
    } catch (_) {
      if (_current(generation)) _providerError = true;
    } finally {
      if (_current(generation)) {
        setState(() => _openingProvider = false);
      }
    }
  }

  @override
  void dispose() {
    _generation += 1;
    _interaction?.removeListener(_interactionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(serverAccountControllerProvider);
    final l10n = AppLocalizations.of(context);
    final copy = _GameStreamCopy.of(context);
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
    final current = _current(_generation);
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
              onTap: current && !_loading ? () => unawaited(_refresh()) : null,
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
                Semantics(
                  container: true,
                  label:
                      '${host.name}. ${host.codecs.join(', ')}. '
                      '${host.maxWidth} × ${host.maxHeight}, ${host.maxFps} FPS.',
                  child: ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        16,
                        12,
                        16,
                        12,
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            CupertinoIcons.desktopcomputer,
                            color: CupertinoColors.systemPurple,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(host.name),
                                const SizedBox(height: 3),
                                Text(
                                  '${host.codecs.join(' · ')} · '
                                  '${host.maxWidth}×${host.maxHeight} · '
                                  '${host.maxFps} FPS',
                                  style: const TextStyle(
                                    color: CupertinoColors.secondaryLabel,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            CupertinoIcons.info_circle,
                            color: CupertinoColors.secondaryLabel,
                          ),
                        ],
                      ),
                    ),
                  ),
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

final class _GameStreamCopy {
  const _GameStreamCopy({
    required this.openProvider,
    required this.openingProvider,
    required this.provider,
    required this.version,
    required this.unknown,
    required this.handoffBoundary,
    required this.handoffAvailable,
    required this.configuredHosts,
    required this.hostsBoundary,
    required this.hostReadFailed,
    required this.signInForHosts,
    required this.noHosts,
    required this.providerLaunchFailed,
  });

  final String openProvider;
  final String openingProvider;
  final String provider;
  final String version;
  final String unknown;
  final String handoffBoundary;
  final String handoffAvailable;
  final String configuredHosts;
  final String hostsBoundary;
  final String hostReadFailed;
  final String signInForHosts;
  final String noHosts;
  final String providerLaunchFailed;

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
    configuredHosts: 'Yapılandırılmış Sunshine bilgisayarları',
    hostsBoundary:
        'Bu liste Core üzerindeki sürüm sabitli, gizli bilgi içermeyen host kayıtlarıdır. '
        'Canlı erişilebilirlik ve fiziksel yayın ayrıca doğrulanır.',
    hostReadFailed: 'Bilgisayar kayıtları Core’dan okunamadı.',
    signInForHosts:
        'Bilgisayarları görmek için geçerli bir Core oturumu gerekir.',
    noHosts: 'Henüz yapılandırılmış bir oyun bilgisayarı yok.',
    providerLaunchFailed: 'Moonlight açılamadı. Uygulamanın kurulu ve kullanılabilir olduğunu denetleyip tekrar deneyin.',
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
    configuredHosts: 'Configured Sunshine computers',
    hostsBoundary:
        'This list contains revision-bound, secret-free host records from Core. '
        'Live reachability and physical streaming require separate verification.',
    hostReadFailed: 'Computer records could not be read from Core.',
    signInForHosts: 'A current Core session is required to show computers.',
    noHosts: 'No game computer has been configured yet.',
    providerLaunchFailed: 'Moonlight could not be opened. Check that the app is installed and available, then try again.',
  );
}
