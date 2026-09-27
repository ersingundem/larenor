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
import '../data/server_evidence_diagnostic_controller.dart';
import '../domain/server_evidence_diagnostic_models.dart';

class ServerEvidenceDiagnosticScreen extends ConsumerStatefulWidget {
  const ServerEvidenceDiagnosticScreen({super.key, required this.gateCurrent});
  final bool Function() gateCurrent;

  @override
  ConsumerState<ServerEvidenceDiagnosticScreen> createState() =>
      _ServerEvidenceDiagnosticScreenState();
}

class _ServerEvidenceDiagnosticScreenState
    extends MediaSessionState<ServerEvidenceDiagnosticScreen> {
  late final ServerAccountController _account;
  late final ServerEvidenceDiagnosticController _diagnostics;
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
    _diagnostics = ServerEvidenceDiagnosticController(_account);
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
  void clearPendingInteraction() => _expire();

  void _expire() {
    if (!mounted || _expired) return;
    _expired = true;
    sessionGeneration++;
    void retire() {
      if (!mounted) return;
      _diagnostics.invalidate();
      setState(() {});
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => retire());
    } else {
      retire();
    }
  }

  String _message(AppLocalizations l10n) => switch (_diagnostics.failure) {
    null => switch (_diagnostics.announcement) {
      'diagnosed' => l10n.serverEvidenceDiagnosticVerified,
      'previewed' => l10n.serverEvidenceDiagnosticPreviewVerified,
      _ => '',
    },
    'diagnostic_sources_empty' => l10n.serverEvidenceDiagnosticNoSources,
    'diagnostic_source_stale' => l10n.serverEvidenceDiagnosticStale,
    _ => l10n.serverEvidenceDiagnosticFailure,
  };

  String _status(AppLocalizations l10n, EvidenceDiagnosis value) =>
      switch (value.status) {
        'fault' => l10n.serverEvidenceDiagnosticFault,
        'unknown' => l10n.serverEvidenceDiagnosticUnknown,
        _ => l10n.serverEvidenceDiagnosticNoIssue,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: _diagnostics,
      builder: (context, _) {
        final diagnosis = _diagnostics.diagnosis;
        final preview = _diagnostics.repairPreview;
        final enabled = _active && !_diagnostics.busy;
        final message = _message(l10n);
        return ServiceRootScaffold(
          title: l10n.serverEvidenceDiagnosticTitle,
          trailing: CupertinoButton(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.all(12),
            onPressed: enabled
                ? () => _diagnostics.diagnose(current: () => mounted && _active)
                : null,
            child: const Icon(CupertinoIcons.waveform_path_ecg),
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
                child: Text(l10n.serverEvidenceDiagnosticIntro),
              ),
            ),
            if (_diagnostics.busy)
              const SliverFilledMessage(
                child: CupertinoActivityIndicator(radius: 14),
              )
            else if (diagnosis == null)
              SliverFilledMessage(
                child: Text(l10n.serverEvidenceDiagnosticRunHint),
              )
            else ...[
              SliverToBoxAdapter(
                child: SettingsSection(
                  header: Text(_status(l10n, diagnosis)),
                  footer: Text(
                    diagnosis.certainty == 'limited'
                        ? l10n.serverEvidenceDiagnosticLimited
                        : l10n.serverEvidenceDiagnosticSupported,
                  ),
                  children: [
                    for (final source in diagnosis.sources)
                      CupertinoListTile(
                        leading: Icon(
                          source.state == 'healthy'
                              ? CupertinoIcons.check_mark_circled_solid
                              : CupertinoIcons.exclamationmark_triangle_fill,
                        ),
                        title: Text(source.id),
                        subtitle: Text(
                          l10n.serverEvidenceDiagnosticSourceValue(
                            source.state,
                            source.revision,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: SettingsSection(
                  header: Text(l10n.serverEvidenceDiagnosticFindings),
                  footer: Text(
                    l10n.serverEvidenceDiagnosticRedactions(
                      diagnosis.redactionCount,
                    ),
                  ),
                  children: [
                    if (diagnosis.findingCodes.isEmpty)
                      CupertinoListTile(
                        title: Text(l10n.serverEvidenceDiagnosticNoFindings),
                      ),
                    for (final code in diagnosis.findingCodes)
                      CupertinoListTile(
                        leading: const Icon(
                          CupertinoIcons.exclamationmark_circle,
                        ),
                        title: Text(code),
                      ),
                    for (final code in diagnosis.unknownCodes)
                      CupertinoListTile(
                        leading: const Icon(CupertinoIcons.question_circle),
                        title: Text(code),
                        subtitle: Text(
                          l10n.serverEvidenceDiagnosticUnknownHint,
                        ),
                      ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: SettingsSection(
                  header: Text(l10n.serverEvidenceDiagnosticRepair),
                  footer: Text(l10n.serverEvidenceDiagnosticPreviewOnly),
                  children: [
                    SettingsActionTile(
                      leading: const Icon(CupertinoIcons.doc_text_search),
                      title: Text(l10n.serverEvidenceDiagnosticPreview),
                      onTap: enabled
                          ? () => _diagnostics.preview(
                              current: () => mounted && _active,
                            )
                          : null,
                    ),
                    if (preview != null)
                      for (final code in preview.stepCodes)
                        CupertinoListTile(
                          title: Text(code),
                          subtitle: Text(
                            l10n.serverEvidenceDiagnosticNotApplied,
                          ),
                        ),
                  ],
                ),
              ),
            ],
            if (message.isNotEmpty || _diagnostics.needsRefresh)
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
    _diagnostics.dispose();
    super.dispose();
  }
}
