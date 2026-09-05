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
import '../../domain/server_models.dart';
import '../../providers/server_providers.dart';
import '../data/server_media_inspections_controller.dart';
import '../domain/server_media_inspection_models.dart';
import '../domain/server_media_preparation_models.dart';

/// Accessed from the PIN-protected Server component screen. Only durable
/// requirements inspection is exposed; no provider credentials or install API.
class ServerMediaInspectionsScreen extends ConsumerStatefulWidget {
  const ServerMediaInspectionsScreen({
    super.key,
    this.preparation,
    this.context,
  });
  final ServerMediaPreparation? preparation;
  final ServerContext? context;
  @override
  ConsumerState<ServerMediaInspectionsScreen> createState() =>
      _ServerMediaInspectionsScreenState();
}

class _ServerMediaInspectionsScreenState
    extends MediaSessionState<ServerMediaInspectionsScreen> {
  late final ServerAccountController _account;
  late final ServerMediaInspectionsController _inspections;
  late final int _accountEpoch;
  ValueListenable<TickerModeData>? _ticker;
  Route<bool>? _dialog;
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
  bool get _enabled => _active && !_inspections.busy;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    final plan = widget.preparation?.plan;
    _inspections = ServerMediaInspectionsController(
      _account,
      context:
          widget.context ??
          (plan == null
              ? null
              : ServerContext.fromJson({
                  'schemaVersion': 1,
                  'coreId': plan.coreId,
                  'homeId': plan.homeId,
                })),
    );
    _account.addListener(_accountChanged);
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
    final wasBusy = _inspections.busy;
    _expired = true;
    sessionGeneration++;
    final route = _dialog;
    _dialog = null;
    void retire() {
      if (!mounted) return;
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
      _inspections.invalidate();
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
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _inspections.dispose();
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

  Future<void> _load(bool Function() current) async {
    await _inspections.load(current: current);
    final preparation = widget.preparation;
    if (current() &&
        !_inspections.canRetryLaunch &&
        preparation != null &&
        _inspections.failure == null) {
      await _inspections.review(preparation, current: current);
    }
  }

  Future<void> _cancel(bool Function() current) async {
    final selected = _inspections.selected;
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
          content: Text(l10n.serverMediaInspectionsCancelBody),
          actions: [
            CupertinoDialogAction(
              onPressed: () {
                if (valid()) Navigator.pop(dialogContext, false);
              },
              child: Text(l10n.commonBack),
            ),
            CupertinoDialogAction(
              key: const ValueKey('inspections-cancel-confirm'),
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
        _inspections.selected?.id == selected.id &&
        _inspections.selected?.revision == selected.revision) {
      await _inspections.cancelSelected(current: current);
    }
  }

  String _failure(AppLocalizations l, String code) => switch (code) {
    'unauthorized' => l.serverFailureAuthentication,
    'forbidden' || 'password_change_required' => l.serverFailurePermission,
    'rate_limited' => l.serverFailureRateLimit,
    'revision_conflict' || 'media_inspection_conflict' => l.serverJobsConflict,
    'media_inspection_limit_reached' => l.serverMediaInspectionsCapacity,
    'media_catalog_changed' || 'catalog_changed' => l.serverMediaCatalogChanged,
    'media_context_changed' || 'context_changed' => l.serverMediaContextChanged,
    'media_preparation_changed' ||
    'preparation_changed' => l.serverMediaInspectionsPreparationChanged,
    'plugin_worker_unavailable' ||
    'worker_unavailable' => l.serverJobsWorkerUnavailable,
    'media_inspection_storage_unavailable' =>
      l.serverMediaInspectionsStorageUnavailable,
    'authority_changed' => l.serverJobsAuthorityChanged,
    'invalid_worker_result' => l.serverJobsInvalidResult,
    _ => l.serverFailureConnection,
  };
  String _date(AppLocalizations l10n, DateTime time) =>
      DateFormat.yMd(l10n.localeName).add_Hm().format(time.toLocal());
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
  Widget _button(
    String key,
    String label,
    FutureOr<void> Function(bool Function()) action, {
    bool allowed = true,
  }) => CupertinoButton(
    key: ValueKey(key),
    onPressed: _enabled && allowed ? _callback(action) : null,
    child: Text(label),
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
        if (mounted && _active) unawaited(_load(_capture()));
      });
    }
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          l.serverMediaInspectionsTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _inspections,
          builder: (context, _) {
            if (!_active) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _account.session?.user.canAdminister == true
                        ? l.serverOpenFromSettings
                        : l.serverFailurePermission,
                  ),
                ),
              );
            }
            final selected = _inspections.selected;
            final preparation = _inspections.preparation;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(l.serverMediaInspectionsIntro),
                    ),
                    if (_inspections.busy)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: CupertinoActivityIndicator(),
                      ),
                    if (_inspections.failure != null)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(_failure(l, _inspections.failure!)),
                        ),
                      ),
                    if (_inspections.canRetryLaunch)
                      _section(l.serverJobsRecovery, [
                        Text(l.serverMediaRecoveryBody),
                        _button(
                          'inspections-recover',
                          l.serverJobsRetry,
                          (current) =>
                              _inspections.retryLaunch(current: current),
                        ),
                      ]),
                    if (selected != null)
                      ..._details(l, selected)
                    else ...[
                      if (preparation != null && !_inspections.canRetryLaunch)
                        _section(l.serverMediaInspectionsReview, [
                          Text(preparation.plan.settings.instanceName),
                          Text(preparation.plan.platform),
                          if (!preparation.prepared ||
                              !preparation.catalogCurrent)
                            Text(l.serverMediaInspectionsReviewUnavailable),
                          if (_inspections.capabilities != null)
                            Text(
                              _inspections.capabilities!.inspectionConfigured
                                  ? l.serverMediaInspectionsConfigured
                                  : l.serverMediaInspectionsUnconfigured,
                            ),
                          _button(
                            'inspections-launch',
                            l.serverMediaInspectionsLaunch,
                            (current) => _inspections.launch(current: current),
                            allowed: _inspections.canLaunch,
                          ),
                        ]),
                      _section(l.serverMediaInspectionsHistory, [
                        _button('inspections-refresh', l.commonRefresh, _load),
                        if (_inspections.inspections.isEmpty &&
                            !_inspections.busy)
                          Text(l.serverJobsEmpty),
                      ]),
                      for (final record in _inspections.inspections)
                        _section(_state(l, record.state), [
                          Text(
                            '${record.platform} · ${_date(l, record.createdAt)}',
                          ),
                          _button(
                            'inspection-view-${record.id}',
                            l.serverJobsView,
                            (current) =>
                                _inspections.select(record, current: current),
                          ),
                        ]),
                      if (_inspections.nextBefore != null &&
                          _inspections.inspections.length <
                              ServerMediaInspectionsController.maximumHistory)
                        _button(
                          'inspections-more',
                          l.serverAdminMore,
                          (current) => _inspections.loadMore(current: current),
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

  List<Widget> _details(AppLocalizations l, ServerMediaInspection record) => [
    _section(l.serverMediaInspectionsReview, [
      Semantics(
        liveRegion: true,
        child: Text(_state(l, record.state), style: AppText.headline),
      ),
      Text('${record.platform} · ${_date(l, record.updatedAt)}'),
      Text('${l.serverMediaInspectionsPreparationId}: ${record.preparationId}'),
      if (record.cancelRequested) Text(l.serverJobsCancelPending),
      if (record.errorCode != null) Text(_failure(l, record.errorCode!)),
      if (_inspections.pollingPaused) Text(l.serverJobsPollingPaused),
      if (_inspections.cancelNeedsRefresh) Text(l.serverJobsConflict),
      Wrap(
        children: [
          _button(
            'inspection-refresh',
            l.commonRefresh,
            (current) => _inspections.refreshSelected(current: current),
          ),
          if (record.active && !record.cancelRequested)
            _button(
              'inspections-cancel',
              l.serverJobsCancel,
              _cancel,
              allowed:
                  !_inspections.cancelNeedsRefresh &&
                  _inspections.failure == null,
            ),
          _button(
            'inspections-history',
            l.serverJobsBackToHistory,
            (_) => _inspections.showList(),
          ),
        ],
      ),
    ]),
    if (record.result != null)
      _section(l.serverJobsResults, [
        Text(l.serverJobsCompletedNote),
        for (final check in record.result!.checks)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_check(l, check.code), style: AppText.subhead),
                Text(switch (check.status) {
                  'passed' => l.serverJobsPassed,
                  'failed' => l.serverJobsCheckFailed,
                  _ => l.serverJobsUnknown,
                }),
                if (check.rootId != null) Text(check.rootId!),
                if (check.availableMiB != null)
                  Text(
                    '${l.serverJobsAvailableSpace}: ${check.availableMiB} MiB',
                  ),
                if (check.requiredMiB != null)
                  Text(
                    '${l.serverJobsRequiredSpace}: ${check.requiredMiB} MiB',
                  ),
              ],
            ),
          ),
      ]),
  ];
}

String _state(AppLocalizations l, String state) => switch (state) {
  'queued' => l.serverJobsQueued,
  'running' => l.serverJobsRunning,
  'succeeded' => l.serverJobsSucceeded,
  'failed' => l.serverJobsFailed,
  'cancelled' => l.serverJobsCancelled,
  _ => l.serverJobsAttention,
};
String _check(AppLocalizations l, String code) => switch (code) {
  'platform' => l.serverJobsCheckPlatform,
  'storage_root' => l.serverJobsCheckRoot,
  'storage_capacity' => l.serverJobsCheckCapacity,
  'docker_engine' => l.serverJobsCheckDocker,
  'daemon_mount_context' => l.serverJobsCheckDaemonMount,
  'daemon_network_context' => l.serverJobsCheckDaemonNetwork,
  'daemon_root_context' => l.serverJobsCheckDaemonRoot,
  'port_availability' => l.serverJobsCheckPorts,
  _ => l.serverJobsCheckNetwork,
};
