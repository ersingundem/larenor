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
import '../data/server_automation_trial_controller.dart';

class ServerAutomationTrialScreen extends ConsumerStatefulWidget {
  const ServerAutomationTrialScreen({super.key, required this.gateCurrent});
  final bool Function() gateCurrent;
  @override
  ConsumerState<ServerAutomationTrialScreen> createState() =>
      _ServerAutomationTrialScreenState();
}

class _ServerAutomationTrialScreenState
    extends MediaSessionState<ServerAutomationTrialScreen> {
  late final ServerAccountController _account;
  late final ServerAutomationTrialController _controller;
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
    _controller = ServerAutomationTrialController(_account);
    _account.addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _active) _controller.load(() => mounted && _active);
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
      _controller.invalidate();
      setState(() {});
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => retire());
    } else {
      retire();
    }
  }

  Future<void> _create(AppLocalizations l10n) async {
    final value = TextEditingController(text: 'UTC');
    final timezone = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.serverAutomationTrialTimezone),
        content: Padding(
          padding: const EdgeInsets.only(top: Gap.lg),
          child: CupertinoTextField(
            controller: value,
            placeholder: 'Europe/Istanbul',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.serverAutomationTrialCancel),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(dialogContext, value.text.trim()),
            child: Text(l10n.serverAutomationTrialStart),
          ),
        ],
      ),
    );
    value.dispose();
    if (timezone != null && timezone.isNotEmpty && mounted && _active) {
      await _controller.create(timezone, () => mounted && _active);
    }
  }

  String _message(AppLocalizations l10n) => switch (_controller.failure) {
    null => switch (_controller.announcement) {
      'created' => l10n.serverAutomationTrialCreated,
      'evaluated' => l10n.serverAutomationTrialEvaluated,
      'replayed' => l10n.serverAutomationReplayVerified,
      _ => '',
    },
    'trial_services_empty' => l10n.serverAutomationTrialNoServices,
    'trial_service_missing' => l10n.serverAutomationTrialServiceMissing,
    'automation_trial_timezone_invalid' =>
      l10n.serverAutomationTrialTimezoneInvalid,
    _ => l10n.serverAutomationTrialFailure,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final trial = _controller.trial;
        final enabled = _active && !_controller.busy;
        final latest = trial?.events.lastOrNull;
        final replay = _controller.replay;
        final message = _message(l10n);
        return ServiceRootScaffold(
          title: l10n.serverAutomationTrialTitle,
          trailing: CupertinoButton(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.all(12),
            onPressed: enabled ? () => _create(l10n) : null,
            child: const Icon(CupertinoIcons.calendar_badge_plus),
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
                child: Text(l10n.serverAutomationTrialIntro),
              ),
            ),
            if (_controller.busy)
              const SliverFilledMessage(
                child: CupertinoActivityIndicator(radius: 14),
              )
            else if (trial == null)
              SliverFilledMessage(child: Text(l10n.serverAutomationTrialEmpty))
            else ...[
              SliverToBoxAdapter(
                child: SettingsSection(
                  header: Text(l10n.serverAutomationTrialReport),
                  footer: Text(l10n.serverAutomationTrialZeroWrites),
                  children: [
                    CupertinoListTile(
                      title: Text(
                        '${trial.localStartDate} · ${trial.timezone}',
                      ),
                      subtitle: Text(
                        l10n.serverAutomationTrialDuration(
                          trial.utcDurationSeconds,
                        ),
                      ),
                    ),
                    CupertinoListTile(
                      title: Text(l10n.serverAutomationTrialDecisions),
                      additionalInfo: Text(
                        '${trial.triggeredCount} / ${trial.suppressedCount}',
                      ),
                      subtitle: Text(l10n.serverAutomationTrialDecisionLegend),
                    ),
                    SettingsActionTile(
                      leading: const Icon(CupertinoIcons.checkmark_shield),
                      title: Text(l10n.serverAutomationTrialRealEvent),
                      onTap: enabled
                          ? () => _controller.evaluate(
                              'real',
                              () => mounted && _active,
                            )
                          : null,
                    ),
                    SettingsActionTile(
                      leading: const Icon(CupertinoIcons.lab_flask),
                      title: Text(l10n.serverAutomationTrialSyntheticEvent),
                      onTap: enabled
                          ? () => _controller.evaluate(
                              'synthetic',
                              () => mounted && _active,
                            )
                          : null,
                    ),
                    SettingsActionTile(
                      leading: const Icon(
                        CupertinoIcons.arrow_counterclockwise,
                      ),
                      title: Text(l10n.serverAutomationReplayRun),
                      onTap: enabled
                          ? () => _controller.replayHistory(
                              () => mounted && _active,
                            )
                          : null,
                    ),
                  ],
                ),
              ),
              if (replay != null)
                SliverToBoxAdapter(
                  child: SettingsSection(
                    header: Text(l10n.serverAutomationReplayTitle),
                    footer: Text(
                      l10n.serverAutomationReplayFingerprint(
                        replay.deterministicFingerprint.substring(0, 12),
                      ),
                    ),
                    children: [
                      CupertinoListTile(
                        leading: Icon(
                          replay.status == 'complete'
                              ? CupertinoIcons.checkmark_shield_fill
                              : CupertinoIcons.question_circle_fill,
                        ),
                        title: Text(
                          replay.status == 'complete'
                              ? l10n.serverAutomationReplayComplete
                              : l10n.serverAutomationReplayUnknown,
                        ),
                        subtitle: Text(
                          l10n.serverAutomationReplayCounts(
                            replay.availableEventCount,
                            replay.requiredEventCount,
                            replay.changedDecisionCount,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (latest != null)
                SliverToBoxAdapter(
                  child: SettingsSection(
                    header: Text(l10n.serverAutomationTrialLatestEvent),
                    footer: Text(
                      l10n.serverAutomationTrialLocalTime(
                        latest.localDateTime,
                        latest.utcOffsetSeconds,
                        latest.fold,
                      ),
                    ),
                    children: [
                      if (latest.decisions.isEmpty)
                        CupertinoListTile(
                          title: Text(l10n.serverAutomationTrialNoDecision),
                        ),
                      for (final decision in latest.decisions)
                        CupertinoListTile(
                          leading: Icon(
                            decision.state == 'triggered'
                                ? CupertinoIcons.play_circle_fill
                                : CupertinoIcons.nosign,
                          ),
                          title: Text(
                            decision.state == 'triggered'
                                ? l10n.serverAutomationTrialTriggered
                                : l10n.serverAutomationTrialSuppressed,
                          ),
                          subtitle: Text(
                            '${decision.action} · ${decision.reason} · P${decision.priority}',
                          ),
                        ),
                    ],
                  ),
                ),
            ],
            if (message.isNotEmpty || _controller.needsRefresh)
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
    _controller.dispose();
    super.dispose();
  }
}
