import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../media/hub/presentation/media_session_state.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_ai_resource_controller.dart';
import '../domain/server_ai_resource_models.dart';

class ServerAiResourceScreen extends ConsumerStatefulWidget {
  const ServerAiResourceScreen({super.key, required this.gateCurrent});
  final bool Function() gateCurrent;

  @override
  ConsumerState<ServerAiResourceScreen> createState() =>
      _ServerAiResourceScreenState();
}

class _ServerAiResourceScreenState
    extends MediaSessionState<ServerAiResourceScreen> {
  late final ServerAccountController _account;
  late final ServerAiResourceController _resources;
  late final int _accountEpoch;
  ValueListenable<TickerModeData>? _ticker;
  bool _visible = true, _expired = false, _loaded = false, _wasCurrent = true;

  bool get _active =>
      !_expired &&
      _visible &&
      sessionCurrent(sessionGeneration) &&
      _account.isCurrent(_accountEpoch) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      widget.gateCurrent() &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    _resources = ServerAiResourceController(_account);
    _account.addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountEpoch) ||
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
    if (_wasCurrent && !current) _expire();
    _wasCurrent = current;
  }

  void _visibilityChanged() {
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _expire();
  }

  @override
  void clearPendingInteraction() => _expire();

  void _expire() {
    if (!mounted || _expired) return;
    _expired = true;
    sessionGeneration++;
    void retire() {
      if (!mounted) return;
      _resources.invalidate();
      setState(() {});
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => retire());
    } else {
      retire();
    }
  }

  Future<void> _load() async {
    if (!_active) return;
    await _resources.load(current: () => mounted && _active);
    if (mounted && _active) setState(() => _loaded = true);
  }

  String _status(AppLocalizations l10n) => switch (_resources.failure) {
    null => switch (_resources.announcement) {
      'policy' => l10n.serverAiResourcesPolicySaved,
      'cancelled' => l10n.serverAiResourcesJobCancelled,
      _ => '',
    },
    'ai_resource_policy_changed' ||
    'ai_resource_job_changed' => l10n.serverAiResourcesConflict,
    'unauthorized' || 'forbidden' => l10n.serverServicesUnauthorized,
    _ => l10n.serverAiResourcesFailure,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: _resources,
      builder: (context, _) {
        final snapshot = _resources.value;
        final enabled = _active && !_resources.busy && !_resources.needsRefresh;
        final message = _status(l10n);
        return ServiceRootScaffold(
          title: l10n.serverAiResourcesTitle,
          trailing: CupertinoButton(
            key: const ValueKey('ai-resources-refresh'),
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.all(12),
            onPressed: enabled ? _load : null,
            child: const Icon(CupertinoIcons.refresh),
          ),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  Gap.xl,
                  Gap.lg,
                  Gap.xl,
                  0,
                ),
                child: Text(l10n.serverAiResourcesIntro),
              ),
            ),
            if (_resources.busy && !_loaded)
              const SliverFilledMessage(
                child: CupertinoActivityIndicator(radius: 14),
              )
            else if (!_active)
              SliverFilledMessage(child: Text(l10n.serverAiResourcesLocked))
            else if (snapshot != null) ...[
              SliverToBoxAdapter(child: _capacity(context, snapshot)),
              SliverToBoxAdapter(
                child: _policy(context, snapshot.policy, enabled),
              ),
              SliverToBoxAdapter(child: _jobs(context, snapshot.jobs, enabled)),
            ],
            if (message.isNotEmpty || _resources.needsRefresh)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _resources.needsRefresh
                          ? l10n.serverAiResourcesConflict
                          : message,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _capacity(BuildContext context, AiResourceSnapshot snapshot) {
    final l10n = AppLocalizations.of(context);
    final value = snapshot.capacity;
    return SettingsSection(
      header: Text(l10n.serverAiResourcesCapacity),
      footer: Text(
        value.mediaActive
            ? l10n.serverAiResourcesMediaActive
            : l10n.serverAiResourcesMediaIdle,
      ),
      children: [
        CupertinoListTile(
          title: Text(l10n.serverAiResourcesHardware),
          subtitle: Text(
            l10n.serverAiResourcesHardwareValue(value.memoryMb, value.cpuCount),
          ),
        ),
        CupertinoListTile(
          title: Text(l10n.serverAiResourcesAllocated),
          subtitle: Text(
            l10n.serverAiResourcesAllocatedValue(
              value.allocatedMemoryMb,
              value.allocatedCpuPercent,
              value.effectiveCpuPercent,
            ),
          ),
        ),
        CupertinoListTile(
          title: Text(l10n.serverAiResourcesMeasured),
          subtitle: Text(
            l10n.serverAiResourcesMeasuredValue(
              value.processMemoryMb,
              value.systemLoadPercent,
            ),
          ),
        ),
      ],
    );
  }

  Widget _policy(BuildContext context, AiResourcePolicy policy, bool enabled) {
    final l10n = AppLocalizations.of(context);
    return SettingsSection(
      header: Text(l10n.serverAiResourcesPolicy),
      footer: Text(
        l10n.serverAiResourcesPolicyValue(
          policy.maxMemoryMb,
          policy.maxCpuPercent,
          policy.maxConcurrentJobs,
          policy.mediaCpuPercent,
        ),
      ),
      children: [
        for (final preset in AiResourcePreset.values)
          SettingsActionTile(
            buttonKey: ValueKey('ai-resource-preset-${preset.name}'),
            leading: Icon(switch (preset) {
              AiResourcePreset.conservative =>
                CupertinoIcons.leaf_arrow_circlepath,
              AiResourcePreset.balanced => CupertinoIcons.equal_circle,
              AiResourcePreset.performance => CupertinoIcons.speedometer,
            }),
            title: Text(switch (preset) {
              AiResourcePreset.conservative =>
                l10n.serverAiResourcesConservative,
              AiResourcePreset.balanced => l10n.serverAiResourcesBalanced,
              AiResourcePreset.performance => l10n.serverAiResourcesPerformance,
            }),
            onTap: enabled
                ? () => _resources.apply(
                    preset,
                    current: () => mounted && _active,
                  )
                : null,
          ),
      ],
    );
  }

  Widget _jobs(BuildContext context, List<AiResourceJob> jobs, bool enabled) {
    final l10n = AppLocalizations.of(context);
    return SettingsSection(
      header: Text(l10n.serverAiResourcesQueue),
      footer: Text(
        jobs.isEmpty
            ? l10n.serverAiResourcesQueueEmpty
            : l10n.serverAiResourcesQueueHint,
      ),
      children: [
        if (jobs.isEmpty)
          CupertinoListTile(title: Text(l10n.serverAiResourcesQueueEmpty))
        else
          for (final job in jobs)
            SettingsActionTile(
              buttonKey: ValueKey('ai-resource-job-${job.id}'),
              leading: Icon(
                job.state == AiResourceJobState.blocked
                    ? CupertinoIcons.exclamationmark_triangle
                    : CupertinoIcons.sparkles,
              ),
              title: Text(job.label),
              additionalInfo: Text(
                l10n.serverAiResourcesJobValue(
                  job.priority,
                  job.memoryMb,
                  job.cpuPercent,
                  _state(l10n, job),
                ),
              ),
              onTap: enabled && job.canCancel && job.ownedByCurrentSession
                  ? () => _resources.cancel(
                      job,
                      current: () => mounted && _active,
                    )
                  : null,
            ),
      ],
    );
  }

  String _state(AppLocalizations l10n, AiResourceJob job) =>
      switch (job.reason) {
        'insufficientHardware' => l10n.serverAiResourcesInsufficientHardware,
        'mediaActive' => l10n.serverAiResourcesMediaThrottled,
        'quotaExceeded' ||
        'higherPriorityWork' => l10n.serverAiResourcesWaiting,
        _ => switch (job.state) {
          AiResourceJobState.running => l10n.serverAiResourcesRunning,
          AiResourceJobState.completed => l10n.serverAiResourcesCompleted,
          AiResourceJobState.cancelled => l10n.serverAiResourcesCancelled,
          _ => l10n.serverAiResourcesWaiting,
        },
      };

  @override
  void dispose() {
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _resources.dispose();
    super.dispose();
  }
}
