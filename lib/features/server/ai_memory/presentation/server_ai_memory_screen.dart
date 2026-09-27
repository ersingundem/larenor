import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../media/hub/presentation/media_session_state.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_ai_memory_controller.dart';
import '../domain/server_ai_memory_models.dart';

class ServerAiMemoryScreen extends ConsumerStatefulWidget {
  const ServerAiMemoryScreen({super.key, required this.gateCurrent});
  final bool Function() gateCurrent;

  @override
  ConsumerState<ServerAiMemoryScreen> createState() =>
      _ServerAiMemoryScreenState();
}

class _ServerAiMemoryScreenState
    extends MediaSessionState<ServerAiMemoryScreen> {
  late final ServerAccountController _account;
  late final ServerAiMemoryController _memory;
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
      _account.session != null &&
      widget.gateCurrent() &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    _memory = ServerAiMemoryController(_account);
    _account.addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountEpoch) || _account.session == null) {
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
      _memory.invalidate();
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
    await _memory.load(current: () => mounted && _active);
    if (mounted && _active) setState(() => _loaded = true);
  }

  Future<void> _edit([AiMemoryRecord? existing]) async {
    if (!_active || _memory.busy || _memory.needsRefresh) return;
    final controller = TextEditingController(text: existing?.content ?? '');
    var duration = 604800;
    final result = await showCupertinoDialog<(String, int)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final l10n = AppLocalizations.of(context);
          return CupertinoAlertDialog(
            title: Text(
              existing == null
                  ? l10n.serverAiMemoryAdd
                  : l10n.serverAiMemoryEdit,
            ),
            content: Padding(
              padding: const EdgeInsets.only(top: Gap.lg),
              child: Column(
                children: [
                  CupertinoTextField(
                    controller: controller,
                    placeholder: l10n.serverAiMemoryContent,
                    minLines: 3,
                    maxLines: 6,
                    maxLength: 2048,
                  ),
                  const SizedBox(height: Gap.lg),
                  Text(l10n.serverAiMemoryDuration),
                  const SizedBox(height: Gap.sm),
                  CupertinoSlidingSegmentedControl<int>(
                    groupValue: duration,
                    children: {
                      86400: Padding(
                        padding: const EdgeInsets.all(Gap.sm),
                        child: Text(l10n.serverAiMemoryOneDay),
                      ),
                      604800: Padding(
                        padding: const EdgeInsets.all(Gap.sm),
                        child: Text(l10n.serverAiMemoryOneWeek),
                      ),
                      2592000: Padding(
                        padding: const EdgeInsets.all(Gap.sm),
                        child: Text(l10n.serverAiMemoryOneMonth),
                      ),
                    },
                    onValueChanged: (value) {
                      if (value != null) setDialogState(() => duration = value);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(l10n.serverAiMemoryCancel),
              ),
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () {
                  final content = controller.text.trim();
                  if (content.isNotEmpty) {
                    Navigator.pop(dialogContext, (content, duration));
                  }
                },
                child: Text(l10n.serverAiMemorySave),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (result == null || !_active) return;
    if (existing == null) {
      await _memory.remember(
        result.$1,
        result.$2,
        current: () => mounted && _active,
      );
    } else {
      await _memory.correct(
        existing,
        result.$1,
        result.$2,
        current: () => mounted && _active,
      );
    }
  }

  Future<void> _forget(AiMemoryRecord memory) async {
    if (!_active || _memory.busy || _memory.needsRefresh) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.serverAiMemoryForget),
        content: Text(memory.content),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.serverAiMemoryCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.serverAiMemoryForget),
          ),
        ],
      ),
    );
    if (confirmed == true && _active) {
      await _memory.forget(memory, current: () => mounted && _active);
    }
  }

  String _message(AppLocalizations l10n) => switch (_memory.failure) {
    null => switch (_memory.announcement) {
      'created' => l10n.serverAiMemoryCreated,
      'corrected' => l10n.serverAiMemoryCorrected,
      'forgotten' => l10n.serverAiMemoryForgotten,
      _ => '',
    },
    'revision_conflict' => l10n.serverAiMemoryConflict,
    _ => l10n.serverAiMemoryFailure,
  };

  String _expiry(double seconds) {
    final value = DateTime.fromMillisecondsSinceEpoch(
      (seconds * Duration.millisecondsPerSecond).round(),
    ).toLocal();
    final text = value.toString();
    return text.length >= 16 ? text.substring(0, 16) : text;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: _memory,
      builder: (context, _) {
        final snapshot = _memory.value;
        final enabled = _active && !_memory.busy && !_memory.needsRefresh;
        final message = _message(l10n);
        return ServiceRootScaffold(
          title: l10n.serverAiMemoryTitle,
          trailing: CupertinoButton(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.all(12),
            onPressed: enabled ? () => _edit() : null,
            child: const Icon(CupertinoIcons.add),
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
                child: Text(l10n.serverAiMemoryIntro),
              ),
            ),
            if (_memory.busy && !_loaded)
              const SliverFilledMessage(
                child: CupertinoActivityIndicator(radius: 14),
              )
            else if (snapshot == null || snapshot.memories.isEmpty)
              SliverFilledMessage(child: Text(l10n.serverAiMemoryEmpty))
            else
              SliverToBoxAdapter(
                child: SettingsSection(
                  children: [
                    for (final item in snapshot.memories)
                      CupertinoListTile(
                        title: Text(item.content),
                        subtitle: Text(
                          l10n.serverAiMemoryDetails(
                            item.source.description,
                            item.learnedBy,
                            _expiry(item.retention.expiresAt),
                          ),
                        ),
                        trailing: CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: enabled ? () => _forget(item) : null,
                          child: const Icon(CupertinoIcons.delete),
                        ),
                        onTap: enabled ? () => _edit(item) : null,
                      ),
                  ],
                ),
              ),
            if (_memory.busy && _loaded)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(Gap.lg),
                  child: Center(child: CupertinoActivityIndicator()),
                ),
              ),
            if (message.isNotEmpty || _memory.needsRefresh)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _memory.needsRefresh
                          ? l10n.serverAiMemoryConflict
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

  @override
  void dispose() {
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _memory.dispose();
    super.dispose();
  }
}
