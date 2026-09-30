import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../media/hub/presentation/media_session_state.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_automation_draft_controller.dart';
import '../platform/local_draft_speech.dart';

class ServerAutomationDraftScreen extends ConsumerStatefulWidget {
  const ServerAutomationDraftScreen({super.key, required this.gateCurrent});
  final bool Function() gateCurrent;

  @override
  ConsumerState<ServerAutomationDraftScreen> createState() =>
      _ServerAutomationDraftScreenState();
}

class _ServerAutomationDraftScreenState
    extends MediaSessionState<ServerAutomationDraftScreen> {
  final _transcript = TextEditingController();
  final _speech = const LocalDraftSpeech();
  bool _voiceBusy = false;
  int _voiceEpoch = 0;
  String? _voiceStatus;
  late final ServerAccountController _account;
  late final ServerAutomationDraftController _controller;
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
    _controller = ServerAutomationDraftController(_account);
    _account.addListener(_accountChanged);
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
  void clearPendingInteraction() {
    _voiceEpoch++;
    _voiceBusy = false;
    _voiceStatus = null;
    unawaited(_speech.cancel());
    _controller.invalidate();
    // Resume permits a fresh gesture only if the same account, PIN gate and
    // route are still authorized. A late recognition never creates a draft.
  }

  Future<void> _voice({bool readBack = false}) async {
    if (!_active || _voiceBusy || _controller.busy) return;
    final epoch = ++_voiceEpoch;
    final generation = sessionGeneration;
    bool current() =>
        mounted &&
        _active &&
        generation == sessionGeneration &&
        epoch == _voiceEpoch;
    final locale = Localizations.localeOf(context).languageCode == 'tr'
        ? 'tr-TR'
        : 'en-US';
    setState(() {
      _voiceBusy = true;
      _voiceStatus = null;
    });
    try {
      if (readBack) {
        await _speech.speak(locale, _transcript.text.trim());
      } else {
        final capability = await _speech.probe();
        if (!current()) return;
        if (!capability.available) {
          throw PlatformException(code: 'modelUnavailable');
        }
        if (!capability.microphoneGranted) {
          final granted = await _speech.requestPermission();
          if (!current()) return;
          _voiceStatus = granted ? 'ready' : 'permissionDenied';
          return; // Permission alone never starts recording.
        }
        final text = await _speech.recognize(locale);
        if (!current()) return;
        _controller.clearDraft();
        _transcript.text = text;
        _voiceStatus = 'recognized';
      }
    } catch (error) {
      if (!current()) return;
      _voiceStatus = error is PlatformException ? error.code : 'unavailable';
    } finally {
      if (current()) setState(() => _voiceBusy = false);
    }
  }

  String _voiceMessage(AppLocalizations l) => switch (_voiceStatus) {
    'recognized' => l.serverAutomationDraftSpeechRecognized,
    'ready' => l.serverAutomationDraftSpeechReady,
    'permissionDenied' => l.serverAutomationDraftSpeechPermission,
    'modelUnavailable' ||
    'voiceUnavailable' ||
    'unavailable' => l.serverAutomationDraftSpeechUnavailable,
    'noSpeech' || 'invalidTranscript' => l.serverAutomationDraftSpeechNoMatch,
    'timeout' => l.serverAutomationDraftSpeechTimeout,
    _ => '',
  };

  void _expire() {
    if (!mounted || _expired) return;
    _expired = true;
    _voiceEpoch++;
    _voiceBusy = false;
    unawaited(_speech.cancel());
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

  String _message(AppLocalizations l10n) => switch (_controller.failure) {
    null => switch (_controller.announcement) {
      'created' => l10n.serverAutomationDraftCreated,
      'activated' => l10n.serverAutomationDraftActivated,
      _ => '',
    },
    'automation_draft_transcript_unsupported' =>
      l10n.serverAutomationDraftUnsupported,
    'automation_draft_target_required' =>
      l10n.serverAutomationDraftSelectTarget,
    'automation_draft_target_missing' =>
      l10n.serverAutomationDraftTargetMissing,
    'automation_draft_expired' => l10n.serverAutomationDraftExpired,
    'automation_draft_changed' ||
    'ha_rule_changed' => l10n.serverAutomationDraftChanged,
    _ => l10n.serverAutomationDraftFailure,
  };

  String _action(AppLocalizations l10n, String action) => action == 'turn_on'
      ? l10n.serverAutomationDraftTurnOn
      : l10n.serverAutomationDraftTurnOff;

  String _step(AppLocalizations l10n, String step) => switch (step) {
    'validate_current_target' => l10n.serverAutomationDraftValidateTarget,
    'create_inert_rule' => l10n.serverAutomationDraftCreateRule,
    _ => step,
  };

  String _sideEffect(AppLocalizations l10n, String value) => switch (value) {
    'creates_automation_rule' => l10n.serverAutomationDraftCreatesRule,
    'does_not_execute_device' => l10n.serverAutomationDraftNoExecution,
    _ => value,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final draft = _controller.draft;
        final enabled = _active && !_controller.busy && !_voiceBusy;
        final message = _message(l10n);
        return ServiceRootScaffold(
          title: l10n.serverAutomationDraftTitle,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  Gap.xl,
                  Gap.lg,
                  Gap.xl,
                  0,
                ),
                child: Text(l10n.serverAutomationDraftIntro),
              ),
            ),
            SliverToBoxAdapter(
              child: SettingsSection(
                header: Text(l10n.serverAutomationDraftTranscript),
                footer: Text(l10n.serverAutomationDraftCatalogGuard),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(Gap.lg),
                    child: CupertinoTextField(
                      key: const ValueKey('automation-draft-transcript'),
                      controller: _transcript,
                      onChanged: (_) => _controller.clearDraft(),
                      enabled: enabled,
                      maxLength: 256,
                      placeholder: l10n.serverAutomationDraftPlaceholder,
                      textInputAction: TextInputAction.done,
                    ),
                  ),
                  SettingsActionTile(
                    buttonKey: const ValueKey('automation-draft-speech'),
                    leading: const Icon(CupertinoIcons.mic),
                    title: Text(l10n.serverAutomationDraftSpeechListen),
                    additionalInfo: Text(l10n.serverAutomationDraftSpeechLocal),
                    onTap: enabled ? () => unawaited(_voice()) : null,
                  ),
                  SettingsActionTile(
                    buttonKey: const ValueKey(
                      'automation-draft-speech-readback',
                    ),
                    leading: const Icon(CupertinoIcons.speaker_2),
                    title: Text(l10n.serverAutomationDraftSpeechReadback),
                    onTap: enabled && _transcript.text.trim().isNotEmpty
                        ? () => unawaited(_voice(readBack: true))
                        : null,
                  ),
                  if (_voiceBusy)
                    SettingsActionTile(
                      leading: const CupertinoActivityIndicator(),
                      title: Text(l10n.commonCancel),
                      onTap: () {
                        _voiceEpoch++;
                        unawaited(_speech.cancel());
                        setState(() => _voiceBusy = false);
                      },
                    ),
                  if (_voiceMessage(l10n).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(Gap.lg),
                      child: Text(_voiceMessage(l10n)),
                    ),
                  SettingsActionTile(
                    buttonKey: const ValueKey('automation-draft-targets'),
                    leading: const Icon(CupertinoIcons.home),
                    title: Text(l10n.serverAutomationDraftSelectTarget),
                    additionalInfo: Text(
                      _controller.selectedTarget?.label ??
                          l10n.serverAutomationDraftTargetHint,
                    ),
                    onTap: enabled
                        ? () => unawaited(
                            _controller.loadTargets(() => mounted && _active),
                          )
                        : null,
                  ),
                  for (final target in _controller.targets)
                    SettingsActionTile(
                      buttonKey: ValueKey(
                        'automation-draft-target-${target.id}',
                      ),
                      leading: const Icon(CupertinoIcons.power),
                      title: Text(target.label),
                      selected: identical(_controller.selectedTarget, target),
                      onTap: enabled
                          ? () => _controller.selectTarget(
                              target,
                              () => mounted && _active,
                            )
                          : null,
                    ),
                  SettingsActionTile(
                    leading: const Icon(CupertinoIcons.eye),
                    title: Text(l10n.serverAutomationDraftPreview),
                    onTap:
                        enabled &&
                            _transcript.text.trim().isNotEmpty &&
                            _controller.selectedTarget != null
                        ? () {
                            FocusScope.of(context).unfocus();
                            _controller.preview(
                              _transcript.text.trim(),
                              () => mounted && _active,
                            );
                          }
                        : null,
                  ),
                ],
              ),
            ),
            if (_controller.busy)
              const SliverFilledMessage(
                child: CupertinoActivityIndicator(radius: 14),
              )
            else if (draft != null) ...[
              SliverToBoxAdapter(
                child: SettingsSection(
                  header: Text(l10n.serverAutomationDraftPreviewTitle),
                  footer: Text(l10n.serverAutomationDraftNoCommand),
                  children: [
                    CupertinoListTile(
                      leading: const Icon(CupertinoIcons.home),
                      title: Text(_controller.targetLabel ?? draft.resourceId),
                      subtitle: Text(
                        '${draft.catalogVersion} · ${draft.resourceId.substring(0, 8)}',
                      ),
                    ),
                    CupertinoListTile(
                      leading: const Icon(CupertinoIcons.bolt),
                      title: Text(_action(l10n, draft.action)),
                      subtitle: Text(
                        l10n.serverAutomationDraftExpires(
                          draft.expiresAt.toLocal().toString(),
                        ),
                      ),
                    ),
                    for (final step in draft.steps)
                      CupertinoListTile(
                        leading: const Icon(
                          CupertinoIcons.checkmark_alt_circle,
                        ),
                        title: Text(_step(l10n, step)),
                      ),
                    for (final effect in draft.sideEffects)
                      CupertinoListTile(
                        leading: const Icon(CupertinoIcons.info_circle),
                        title: Text(_sideEffect(l10n, effect)),
                      ),
                    if (!draft.activated)
                      SettingsActionTile(
                        leading: const Icon(CupertinoIcons.checkmark_shield),
                        title: Text(l10n.serverAutomationDraftConfirm),
                        onTap: enabled && !draft.expired
                            ? () =>
                                  _controller.activate(() => mounted && _active)
                            : null,
                      ),
                  ],
                ),
              ),
              if (draft.rule != null)
                SliverToBoxAdapter(
                  child: SettingsSection(
                    header: Text(l10n.serverAutomationDraftRuleTitle),
                    footer: Text(l10n.serverAutomationDraftRuleNotRun),
                    children: [
                      CupertinoListTile(
                        leading: const Icon(
                          CupertinoIcons.checkmark_shield_fill,
                        ),
                        title: Text(draft.rule!.id.substring(0, 12)),
                        subtitle: Text(_action(l10n, draft.rule!.action)),
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
            if (_controller.needsRefresh)
              SliverToBoxAdapter(
                child: SettingsSection(
                  children: [
                    SettingsActionTile(
                      buttonKey: const ValueKey('automation-draft-retry'),
                      leading: const Icon(CupertinoIcons.refresh),
                      title: Text(l10n.commonRetry),
                      onTap: enabled
                          ? () => unawaited(
                              _controller.loadTargets(() => mounted && _active),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _voiceEpoch++;
    unawaited(_speech.cancel());
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _transcript.dispose();
    _controller.dispose();
    super.dispose();
  }
}
