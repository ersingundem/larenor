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
import '../data/server_mini_plugin_controller.dart';
import '../domain/server_mini_plugin_models.dart';

class ServerMiniPluginScreen extends ConsumerStatefulWidget {
  const ServerMiniPluginScreen({super.key, required this.gateCurrent});
  final bool Function() gateCurrent;

  @override
  ConsumerState<ServerMiniPluginScreen> createState() =>
      _ServerMiniPluginScreenState();
}

class _ServerMiniPluginScreenState
    extends MediaSessionState<ServerMiniPluginScreen> {
  late final ServerAccountController _account;
  late final ServerMiniPluginController _controller;
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
    _controller = ServerMiniPluginController(_account);
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
    final input = TextEditingController(text: l10n.serverMiniPluginDefaultName);
    final name = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.serverMiniPluginCreate),
        content: Padding(
          padding: const EdgeInsets.only(top: Gap.lg),
          child: CupertinoTextField(controller: input, maxLength: 48),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.serverMiniPluginCancel),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(dialogContext, input.text.trim()),
            child: Text(l10n.serverMiniPluginCreate),
          ),
        ],
      ),
    );
    input.dispose();
    if (name != null && name.isNotEmpty && mounted && _active) {
      await _controller.create(name, () => mounted && _active);
    }
  }

  String _message(AppLocalizations l10n) => switch (_controller.failure) {
    null => switch (_controller.announcement) {
      'created' => l10n.serverMiniPluginCreated,
      'rendered' => l10n.serverMiniPluginRendered,
      'stopped' => l10n.serverMiniPluginStopped,
      _ => '',
    },
    'mini_plugin_limit_reached' ||
    'mini_plugin_running_limit_reached' => l10n.serverMiniPluginLimit,
    'mini_plugin_changed' => l10n.serverMiniPluginChanged,
    'mini_plugin_stopped' => l10n.serverMiniPluginAlreadyStopped,
    _ => l10n.serverMiniPluginFailure,
  };

  Widget _instance(
    AppLocalizations l10n,
    ServerMiniPluginInstance instance,
    bool enabled,
  ) => SettingsSection(
    header: Text(instance.displayName),
    footer: Text(l10n.serverMiniPluginIsolation),
    children: [
      CupertinoListTile(
        leading: Icon(
          instance.running
              ? CupertinoIcons.play_circle_fill
              : CupertinoIcons.stop_circle_fill,
        ),
        title: Text(
          instance.running
              ? l10n.serverMiniPluginRunning
              : l10n.serverMiniPluginStoppedState,
        ),
        subtitle: Text(
          'home.resource_count.read · ${instance.id.substring(0, 8)}',
        ),
      ),
      if (instance.running)
        SettingsActionTile(
          leading: const Icon(CupertinoIcons.chart_bar),
          title: Text(l10n.serverMiniPluginRun),
          onTap: enabled
              ? () => _controller.render(instance, () => mounted && _active)
              : null,
        ),
      if (instance.running)
        SettingsActionTile(
          leading: const Icon(CupertinoIcons.stop_circle),
          title: Text(l10n.serverMiniPluginStop),
          onTap: enabled
              ? () => _controller.stop(instance, () => mounted && _active)
              : null,
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final enabled = _active && !_controller.busy;
        final message = _message(l10n);
        final snapshot = _controller.snapshot;
        return ServiceRootScaffold(
          title: l10n.serverMiniPluginTitle,
          trailing: CupertinoButton(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.all(12),
            onPressed: enabled && _controller.catalog != null
                ? () => _create(l10n)
                : null,
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
                child: Text(l10n.serverMiniPluginIntro),
              ),
            ),
            if (_controller.busy)
              const SliverFilledMessage(
                child: CupertinoActivityIndicator(radius: 14),
              )
            else if (_controller.instances.isEmpty)
              SliverFilledMessage(child: Text(l10n.serverMiniPluginEmpty))
            else
              for (final instance in _controller.instances)
                SliverToBoxAdapter(child: _instance(l10n, instance, enabled)),
            if (snapshot != null)
              SliverToBoxAdapter(
                child: SettingsSection(
                  header: Text(l10n.serverMiniPluginOutput),
                  footer: Text(l10n.serverMiniPluginZeroEffects),
                  children: [
                    CupertinoListTile(
                      leading: const Icon(CupertinoIcons.home),
                      title: Text(
                        l10n.serverMiniPluginResourceCount(
                          snapshot.resourceCount,
                        ),
                      ),
                      subtitle: Text(snapshot.generatedAt.toLocal().toString()),
                    ),
                  ],
                ),
              ),
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
