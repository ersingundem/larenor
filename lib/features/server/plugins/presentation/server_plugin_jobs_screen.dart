import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../media/hub/presentation/media_session_state.dart';
import '../../../settings/providers/settings_providers.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_plugin_jobs_controller.dart';
import '../domain/server_plugin_job_models.dart';
import '../domain/server_plugin_models.dart';

/// Accessed from the PIN-protected Server component screen. Only durable
/// requirements inspection is exposed; no provider credentials or install API.
class ServerPluginJobsScreen extends ConsumerStatefulWidget {
  const ServerPluginJobsScreen({super.key, this.preview});
  final ServerPluginPreview? preview;
  @override
  ConsumerState<ServerPluginJobsScreen> createState() =>
      _ServerPluginJobsScreenState();
}

class _ServerPluginJobsScreenState
    extends MediaSessionState<ServerPluginJobsScreen> {
  late final ServerAccountController _account;
  late final ServerPluginJobsController _jobs;
  late final int _accountEpoch;
  ValueListenable<TickerModeData>? _ticker;
  Route<bool>? _dialog;
  Timer? _expiryTimer;
  bool _visible = true,
      _expired = false,
      _loaded = false,
      _pinReady = false,
      _wasCurrent = true;
  bool get _active =>
      !_expired &&
      _visible &&
      _pinReady &&
      sessionCurrent(sessionGeneration) &&
      _account.isCurrent(_accountEpoch) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      (ModalRoute.of(context)?.isCurrent == true || _dialog?.isCurrent == true);
  bool get _enabled => _active && !_jobs.busy;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    _jobs = ServerPluginJobsController(_account);
    _account.addListener(_accountChanged);
    final preview = widget.preview;
    if (preview != null) {
      final delay = preview.expiresAt.difference(DateTime.now().toUtc());
      if (delay > Duration.zero) {
        _expiryTimer = Timer(delay, () {
          if (mounted) setState(() {});
        });
      }
    }
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountEpoch) ||
        _account.working ||
        _account.session?.user.canAdminister != true) {
      _expire();
    }
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
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_wasCurrent && !current && _dialog == null) _expire();
    _wasCurrent = current;
  }

  void _visibilityChanged() {
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _expire();
  }

  @override
  void clearPendingInteraction() => _expire();
  void _expire() {
    if (!mounted) return;
    final wasBusy = _jobs.busy;
    _expired = true;
    sessionGeneration++;
    _expiryTimer?.cancel();
    final route = _dialog;
    _dialog = null;
    void retire() {
      if (!mounted) return;
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
      _jobs.invalidate();
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => retire());
    } else {
      retire();
    }
    if (wasBusy && !_account.working) unawaited(_account.cancelPending());
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _jobs.dispose();
    super.dispose();
  }

  bool Function() _capture() {
    final epoch = sessionGeneration;
    return () => mounted && sessionCurrent(epoch) && _active;
  }

  VoidCallback _callback(FutureOr<void> Function(bool Function()) action) {
    final current = _capture();
    return () {
      if (current()) action(current);
    };
  }

  Future<void> _load(bool Function() current) => _jobs.load(current: current);
  Future<void> _cancel(bool Function() current) async {
    final selected = _jobs.selected;
    if (!_enabled ||
        selected == null ||
        !selected.active ||
        selected.cancelRequested ||
        _dialog != null) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    late final CupertinoDialogRoute<bool> route;
    route = CupertinoDialogRoute<bool>(
      context: context,
      builder: (dialogContext) {
        if (ModalRoute.isCurrentOf(dialogContext) != true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && identical(_dialog, route) && !route.isCurrent) {
              _expire();
            }
          });
        }
        bool valid() =>
            current() && identical(_dialog, route) && route.isCurrent;
        return CupertinoAlertDialog(
          title: Text(l10n.serverJobsCancelTitle),
          content: Text(l10n.serverJobsCancelBody),
          actions: [
            CupertinoDialogAction(
              onPressed: () {
                if (valid()) Navigator.pop(dialogContext, false);
              },
              child: Text(l10n.commonBack),
            ),
            CupertinoDialogAction(
              key: const ValueKey('jobs-cancel-confirm'),
              isDestructiveAction: true,
              onPressed: () {
                if (valid()) Navigator.pop(dialogContext, true);
              },
              child: Text(l10n.serverJobsCancel),
            ),
          ],
        );
      },
    );
    _dialog = route;
    final confirmed = await Navigator.of(context).push(route);
    if (identical(_dialog, route)) _dialog = null;
    // Polling can observe a revision change while a confirmation is open. A
    // confirmation always belongs to the exact row/revision the user reviewed.
    if (confirmed == true &&
        current() &&
        _jobs.selected?.id == selected.id &&
        _jobs.selected?.revision == selected.revision) {
      await _jobs.cancelSelected(current: current);
    }
  }

  String _failure(AppLocalizations l10n, String code) => switch (code) {
    'unauthorized' => l10n.serverFailureAuthentication,
    'forbidden' || 'password_change_required' => l10n.serverFailurePermission,
    'rate_limited' => l10n.serverFailureRateLimit,
    'revision_conflict' || 'plugin_job_conflict' => l10n.serverJobsConflict,
    'plugin_job_limit_reached' => l10n.serverJobsCapacity,
    'plugin_preview_expired' => l10n.serverPluginsPreviewExpired,
    'plugin_catalog_changed' ||
    'catalog_changed' => l10n.serverJobsCatalogChanged,
    'plugin_worker_unavailable' ||
    'worker_unavailable' => l10n.serverJobsWorkerUnavailable,
    'plugin_job_storage_unavailable' ||
    'storage_unavailable' => l10n.serverJobsStorageUnavailable,
    'authority_changed' => l10n.serverJobsAuthorityChanged,
    'invalid_worker_result' => l10n.serverJobsInvalidResult,
    _ => l10n.serverFailureConnection,
  };
  String _date(AppLocalizations l10n, DateTime time) =>
      DateFormat.yMd(l10n.localeName).add_Hm().format(time.toLocal());
  String _service(AppLocalizations l10n, String id) => switch (id) {
    'jellyfin' => 'Jellyfin',
    'seerr' => 'Seerr',
    'sonarr' => 'Sonarr',
    'radarr' => 'Radarr',
    'qbittorrent' => 'qBittorrent',
    _ => l10n.serverPluginsIntegratedMusic,
  };
  Widget _section(String title, List<Widget> children) => SettingsSection(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    children: [
      Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: AppText.headline),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
        if (mounted && _active) unawaited(_load(_capture()));
      });
    }
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          l10n.serverJobsTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _jobs,
          builder: (context, _) {
            if (!_active) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _account.session?.user.canAdminister == true
                        ? l10n.serverOpenFromSettings
                        : l10n.serverFailurePermission,
                  ),
                ),
              );
            }
            final selected = _jobs.selected;
            final preview = widget.preview;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(l10n.serverJobsIntro),
                    ),
                    if (_jobs.busy)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: CupertinoActivityIndicator(),
                      ),
                    if (_jobs.failure != null)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(_failure(l10n, _jobs.failure!)),
                        ),
                      ),
                    if (_jobs.canRetryLaunch)
                      _section(l10n.serverJobsRecovery, [
                        CupertinoButton(
                          key: const ValueKey('jobs-recover'),
                          onPressed: _enabled
                              ? _callback(
                                  (current) =>
                                      _jobs.retryLaunch(current: current),
                                )
                              : null,
                          child: Text(l10n.serverJobsRetry),
                        ),
                      ]),
                    if (preview != null &&
                        selected == null &&
                        !_jobs.canRetryLaunch)
                      _section(l10n.serverJobsPendingReview, [
                        Text(_service(l10n, preview.plan.serviceId)),
                        Text(preview.plan.image.platform),
                        Text(
                          preview.expired(DateTime.now().toUtc())
                              ? l10n.serverPluginsPreviewExpired
                              : '${l10n.serverPluginsExpires}: ${_date(l10n, preview.expiresAt)}',
                        ),
                        if (_jobs.capabilities != null)
                          Text(
                            _jobs.capabilities!.preflightConfigured
                                ? l10n.serverJobsConfigured
                                : l10n.serverJobsUnconfigured,
                          ),
                        CupertinoButton(
                          key: const ValueKey('jobs-launch'),
                          onPressed:
                              _enabled &&
                                  _jobs.canLaunch &&
                                  !preview.expired(DateTime.now().toUtc())
                              ? _callback(
                                  (current) =>
                                      _jobs.launch(preview, current: current),
                                )
                              : null,
                          child: Text(l10n.serverJobsLaunch),
                        ),
                      ]),
                    if (selected != null)
                      ..._details(l10n, selected)
                    else ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Wrap(
                          children: [
                            Text(
                              l10n.serverJobsHistory,
                              style: AppText.headline,
                            ),
                            CupertinoButton(
                              key: const ValueKey('jobs-refresh'),
                              onPressed: _enabled ? _callback(_load) : null,
                              child: Text(l10n.commonRefresh),
                            ),
                          ],
                        ),
                      ),
                      if (_jobs.jobs.isEmpty && !_jobs.busy)
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(l10n.serverJobsEmpty),
                        ),
                      for (final job in _jobs.jobs)
                        _section(_service(l10n, job.serviceId), [
                          Text(_state(l10n, job.state)),
                          Text(
                            '${job.platform} · ${_date(l10n, job.createdAt)}',
                          ),
                          CupertinoButton(
                            key: ValueKey('job-view-${job.id}'),
                            onPressed: _enabled
                                ? _callback(
                                    (current) =>
                                        _jobs.select(job, current: current),
                                  )
                                : null,
                            child: Text(l10n.serverJobsView),
                          ),
                        ]),
                      if (_jobs.nextBefore != null && _jobs.jobs.length < 250)
                        CupertinoButton(
                          key: const ValueKey('jobs-more'),
                          onPressed: _enabled
                              ? _callback(
                                  (current) => _jobs.loadMore(current: current),
                                )
                              : null,
                          child: Text(l10n.serverJobsLoadMore),
                        ),
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

  List<Widget> _details(AppLocalizations l10n, ServerPluginJob job) => [
    _section(_service(l10n, job.serviceId), [
      Semantics(
        liveRegion: true,
        child: Text(_state(l10n, job.state), style: AppText.headline),
      ),
      Text('${job.platform} · ${_date(l10n, job.updatedAt)}'),
      if (job.cancelRequested) Text(l10n.serverJobsCancelPending),
      if (job.errorCode != null) Text(_failure(l10n, job.errorCode!)),
      if (_jobs.pollingPaused) Text(l10n.serverJobsPollingPaused),
      Wrap(
        children: [
          CupertinoButton(
            key: const ValueKey('job-refresh'),
            onPressed: _enabled
                ? _callback(
                    (current) => _jobs.refreshSelected(current: current),
                  )
                : null,
            child: Text(l10n.commonRefresh),
          ),
          if (job.active && !job.cancelRequested)
            CupertinoButton(
              key: const ValueKey('jobs-cancel'),
              onPressed: _enabled && _jobs.failure == null
                  ? _callback(_cancel)
                  : null,
              child: Text(l10n.serverJobsCancel),
            ),
          CupertinoButton(
            key: const ValueKey('jobs-history'),
            onPressed: _enabled
                ? _callback((_) => _jobs.clearSelected())
                : null,
            child: Text(l10n.serverJobsBackToHistory),
          ),
        ],
      ),
    ]),
    if (job.result != null)
      _section(l10n.serverJobsResults, [
        Text(l10n.serverJobsCompletedNote),
        for (final check in job.result!.checks)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_check(l10n, check.code), style: AppText.subhead),
                Text(switch (check.status) {
                  'passed' => l10n.serverJobsPassed,
                  'failed' => l10n.serverJobsCheckFailed,
                  _ => l10n.serverJobsUnknown,
                }),
                if (check.rootId != null) Text(check.rootId!),
                if (check.availableMiB != null)
                  Text(
                    '${l10n.serverJobsAvailableSpace}: ${check.availableMiB} MiB',
                  ),
                if (check.requiredMiB != null)
                  Text(
                    '${l10n.serverJobsRequiredSpace}: ${check.requiredMiB} MiB',
                  ),
              ],
            ),
          ),
      ]),
    if (_jobs.events.isNotEmpty)
      _section(l10n.serverJobsEvents, [
        for (final event in _jobs.events)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '${_event(l10n, event.code)} · ${_date(l10n, event.createdAt)}',
            ),
          ),
        if (_jobs.nextAfter != null && _jobs.events.length < 250)
          CupertinoButton(
            key: const ValueKey('job-more-events'),
            onPressed: _enabled
                ? _callback((current) => _jobs.loadMoreEvents(current: current))
                : null,
            child: Text(l10n.serverJobsMoreEvents),
          ),
      ]),
  ];
}

String _state(AppLocalizations l10n, String state) => switch (state) {
  'queued' => l10n.serverJobsQueued,
  'running' => l10n.serverJobsRunning,
  'succeeded' => l10n.serverJobsSucceeded,
  'failed' => l10n.serverJobsFailed,
  'cancelled' => l10n.serverJobsCancelled,
  _ => l10n.serverJobsAttention,
};
String _event(AppLocalizations l10n, String code) => switch (code) {
  'job_queued' => l10n.serverJobsQueued,
  'job_started' => l10n.serverJobsRunning,
  'job_resumed' => l10n.serverJobsEventResumed,
  'job_completed' => l10n.serverJobsSucceeded,
  'job_failed' => l10n.serverJobsFailed,
  'job_cancel_requested' => l10n.serverJobsCancelPending,
  'job_cancelled' => l10n.serverJobsCancelled,
  _ => l10n.serverJobsAttention,
};
String _check(AppLocalizations l10n, String code) => switch (code) {
  'platform' => l10n.serverJobsCheckPlatform,
  'storage_root' => l10n.serverJobsCheckRoot,
  'storage_capacity' => l10n.serverJobsCheckCapacity,
  'docker_engine' => l10n.serverJobsCheckDocker,
  'port_availability' => l10n.serverJobsCheckPorts,
  _ => l10n.serverJobsCheckNetwork,
};
