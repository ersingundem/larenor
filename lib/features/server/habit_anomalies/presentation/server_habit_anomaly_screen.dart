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
import '../data/server_habit_anomaly_controller.dart';
import '../domain/server_habit_anomaly_models.dart';

class ServerHabitAnomalyScreen extends ConsumerStatefulWidget {
  const ServerHabitAnomalyScreen({super.key, required this.gateCurrent});
  final bool Function() gateCurrent;

  @override
  ConsumerState<ServerHabitAnomalyScreen> createState() =>
      _ServerHabitAnomalyScreenState();
}

class _ServerHabitAnomalyScreenState
    extends MediaSessionState<ServerHabitAnomalyScreen> {
  late final ServerAccountController _account;
  late final ServerHabitAnomalyController _anomalies;
  late final int _accountEpoch;
  ValueListenable<TickerModeData>? _ticker;
  bool _visible = true, _expired = false, _wasCurrent = true;

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
    _anomalies = ServerHabitAnomalyController(_account);
    _account.addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _active) {
        _anomalies.load(current: () => mounted && _active);
      }
    });
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
      _anomalies.invalidate();
      setState(() {});
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => retire());
    } else {
      retire();
    }
  }

  String _message(AppLocalizations l10n) => switch (_anomalies.failure) {
    null => switch (_anomalies.announcement) {
      'observed' => l10n.serverHabitAnomalyObserved,
      'marked' => l10n.serverHabitAnomalyFeedbackSaved,
      _ => '',
    },
    'habit_services_empty' => l10n.serverHabitAnomalyNoServices,
    'habit_observation_stale' => l10n.serverHabitAnomalyStale,
    'habit_feedback_changed' ||
    'habit_observation_changed' => l10n.serverHabitAnomalyConflict,
    _ => l10n.serverHabitAnomalyFailure,
  };

  String _classification(AppLocalizations l10n, HabitAnomalyReport report) =>
      switch (report.classification) {
        'anomaly' => l10n.serverHabitAnomalyDetected,
        'normal' => l10n.serverHabitAnomalyNormal,
        _ => switch (report.unknownReason) {
          'stale_data' => l10n.serverHabitAnomalyUnknownStale,
          'insufficient_span' => l10n.serverHabitAnomalyUnknownSpan,
          _ => l10n.serverHabitAnomalyUnknownSamples,
        },
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: _anomalies,
      builder: (context, _) {
        final report = _anomalies.report;
        final enabled = _active && !_anomalies.busy;
        final message = _message(l10n);
        return ServiceRootScaffold(
          title: l10n.serverHabitAnomalyTitle,
          trailing: CupertinoButton(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.all(12),
            onPressed: enabled
                ? () => _anomalies.observe(current: () => mounted && _active)
                : null,
            child: const Icon(CupertinoIcons.waveform_path),
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
                child: Text(l10n.serverHabitAnomalyIntro),
              ),
            ),
            if (_anomalies.busy)
              const SliverFilledMessage(
                child: CupertinoActivityIndicator(radius: 14),
              )
            else if (report == null)
              SliverFilledMessage(child: Text(l10n.serverHabitAnomalyEmpty))
            else ...[
              SliverToBoxAdapter(
                child: SettingsSection(
                  header: Text(_classification(l10n, report)),
                  footer: Text(
                    l10n.serverHabitAnomalyModel(
                      report.modelVersion,
                      report.sampleCount,
                      report.minimumBaselineSamples + 1,
                    ),
                  ),
                  children: [
                    CupertinoListTile(
                      leading: Icon(
                        report.classification == 'anomaly'
                            ? CupertinoIcons.exclamationmark_triangle_fill
                            : report.classification == 'normal'
                            ? CupertinoIcons.check_mark_circled_solid
                            : CupertinoIcons.question_circle_fill,
                      ),
                      title: Text(l10n.serverHabitAnomalyUnavailableServices),
                      additionalInfo: Text(
                        report.current.value.toStringAsFixed(0),
                      ),
                    ),
                    if (report.baseline case final baseline?)
                      CupertinoListTile(
                        title: Text(l10n.serverHabitAnomalyBaseline),
                        subtitle: Text(
                          l10n.serverHabitAnomalyBaselineValue(
                            baseline.center.toStringAsFixed(2),
                            baseline.tolerance.toStringAsFixed(2),
                            baseline.sampleCount,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: SettingsSection(
                  header: Text(l10n.serverHabitAnomalyFeedback),
                  footer: Text(
                    report.current.feedback == null
                        ? l10n.serverHabitAnomalyFeedbackHint
                        : l10n.serverHabitAnomalyFeedbackRecorded(
                            report.current.feedback!,
                          ),
                  ),
                  children: [
                    SettingsActionTile(
                      leading: const Icon(CupertinoIcons.check_mark),
                      title: Text(l10n.serverHabitAnomalyMarkNormal),
                      onTap: enabled && report.current.feedback == null
                          ? () => _anomalies.mark(
                              label: 'normal',
                              current: () => mounted && _active,
                            )
                          : null,
                    ),
                    SettingsActionTile(
                      leading: const Icon(CupertinoIcons.hand_thumbsdown),
                      title: Text(l10n.serverHabitAnomalyMarkFalsePositive),
                      onTap: enabled && report.current.feedback == null
                          ? () => _anomalies.mark(
                              label: 'false_positive',
                              current: () => mounted && _active,
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ],
            if (message.isNotEmpty || _anomalies.needsRefresh)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Semantics(liveRegion: true, child: Text(message)),
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _anomalies.dispose();
    super.dispose();
  }
}
