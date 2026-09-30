import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
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
import '../data/server_power_recovery_controller.dart';
import '../domain/server_power_recovery_models.dart';

final class _TargetDraft {
  _TargetDraft({
    required this.id,
    String label = '',
    this.kind = PowerTargetKind.service,
    int order = 10,
    this.start = true,
    int timeout = 30,
  }) : label = TextEditingController(text: label),
       order = TextEditingController(text: '$order'),
       timeout = TextEditingController(text: '$timeout');

  final String id;
  final TextEditingController label;
  final TextEditingController order;
  final TextEditingController timeout;
  PowerTargetKind kind;
  bool start;

  void dispose() {
    label.dispose();
    order.dispose();
    timeout.dispose();
  }
}

class ServerPowerRecoveryScreen extends ConsumerStatefulWidget {
  const ServerPowerRecoveryScreen({super.key});

  @override
  ConsumerState<ServerPowerRecoveryScreen> createState() =>
      _ServerPowerRecoveryScreenState();
}

class _ServerPowerRecoveryScreenState
    extends MediaSessionState<ServerPowerRecoveryScreen> {
  late final ServerAccountController _account;
  late final ServerPowerRecoveryController _power;
  late final int _accountEpoch;
  final _source = TextEditingController();
  final _sourceToken = TextEditingController();
  final _criticalSeconds = TextEditingController(text: '300');
  final _stableSeconds = TextEditingController(text: '60');
  final _targets = <_TargetDraft>[];
  ValueListenable<TickerModeData>? _ticker;
  bool _visible = true, _expired = false, _loaded = false, _pinReady = false;
  bool _wasCurrent = true, _invalid = false;

  bool get _active =>
      !_expired &&
      _visible &&
      _pinReady &&
      sessionCurrent(sessionGeneration) &&
      _account.isCurrent(_accountEpoch) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    _power = ServerPowerRecoveryController(_account);
    _account.addListener(_accountChanged);
    _targets.add(_TargetDraft(id: _id()));
  }

  static String _id() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
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
    _sourceToken.clear();
    _power.invalidate();
  }

  bool Function() _capture() {
    final epoch = sessionGeneration;
    return () => mounted && sessionCurrent(epoch) && _active;
  }

  Future<void> _load() async {
    await _power.load(current: _capture());
    if (!mounted || !_active) return;
    final policy = _power.value?.policy;
    if (policy == null) return;
    _source.text = policy.sourceId;
    _criticalSeconds.text = '${policy.criticalRuntimeSeconds}';
    _stableSeconds.text = '${policy.restoreStableSeconds}';
    for (final target in _targets) {
      target.dispose();
    }
    _targets
      ..clear()
      ..addAll(
        policy.targets.map(
          (target) => _TargetDraft(
            id: target.targetId,
            label: target.label,
            kind: target.kind,
            order: target.shutdownOrder,
            start: target.startOnRestore,
            timeout: target.timeoutSeconds,
          ),
        ),
      );
    setState(() {});
  }

  List<PowerRecoveryTarget>? _takeTargets() {
    final values = <PowerRecoveryTarget>[];
    for (final draft in _targets) {
      final label = draft.label.text.trim();
      final order = int.tryParse(draft.order.text.trim());
      final timeout = int.tryParse(draft.timeout.text.trim());
      if (label.isEmpty ||
          label.length > 80 ||
          label.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
          order == null ||
          order < 1 ||
          order > 1000 ||
          timeout == null ||
          timeout < 5 ||
          timeout > 300) {
        return null;
      }
      values.add(
        PowerRecoveryTarget(
          targetId: draft.id,
          label: label,
          kind: draft.kind,
          shutdownOrder: order,
          startOnRestore: draft.start,
          timeoutSeconds: timeout,
        ),
      );
    }
    values.sort((a, b) => a.shutdownOrder.compareTo(b.shutdownOrder));
    final orders = values.map((item) => item.shutdownOrder).toSet();
    final core = values.where((item) => item.kind == PowerTargetKind.coreHost);
    if (values.isEmpty ||
        orders.length != values.length ||
        core.length > 1 ||
        core.isNotEmpty && core.single != values.last) {
      return null;
    }
    return values;
  }

  Future<void> _save() async {
    final source = _source.text.trim();
    final token = _sourceToken.text;
    final critical = int.tryParse(_criticalSeconds.text.trim());
    final stable = int.tryParse(_stableSeconds.text.trim());
    final targets = _takeTargets();
    final valid =
        RegExp(r'^[A-Za-z0-9_.:-]{1,64}$').hasMatch(source) &&
        token.length >= 32 &&
        utf8.encode(token).length <= 512 &&
        !token.contains(RegExp(r'[\x00-\x1f\x7f]')) &&
        critical != null &&
        critical >= 60 &&
        critical <= 3600 &&
        stable != null &&
        stable >= 30 &&
        stable <= 3600 &&
        targets != null;
    if (!valid) {
      setState(() => _invalid = true);
      return;
    }
    setState(() => _invalid = false);
    await _power.configure(
      sourceId: source,
      sourceToken: token,
      criticalRuntimeSeconds: critical,
      restoreStableSeconds: stable,
      targets: targets,
      current: _capture(),
    );
    _sourceToken.clear();
  }

  @override
  void dispose() {
    _account.removeListener(_accountChanged);
    _ticker?.removeListener(_visibilityChanged);
    _sourceToken.clear();
    _source.dispose();
    _sourceToken.dispose();
    _criticalSeconds.dispose();
    _stableSeconds.dispose();
    for (final target in _targets) {
      target.dispose();
    }
    _power.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pin = ref.watch(pinLockProvider);
    _pinReady = !pin.isLoading && !pin.hasError;
    ref.listen(pinLockProvider, (previous, next) {
      if (next.isLoading ||
          next.hasError ||
          previous?.hasValue == true && previous?.value != next.value) {
        _expire();
      }
    });
    if (_active && !_loaded) {
      _loaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _active) unawaited(_load());
      });
    }
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.serverPowerRecoveryTitle),
        trailing: CupertinoButton(
          key: const ValueKey('server-power-recovery-refresh'),
          padding: EdgeInsets.zero,
          onPressed: _active && !_power.busy ? _load : null,
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _power,
          builder: (context, _) {
            if (!_active) {
              return Center(child: Text(l10n.serverOpenFromSettings));
            }
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    if (_power.busy) const CupertinoActivityIndicator(),
                    if (_power.failure != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(l10n.serverPowerRecoveryFailed),
                      ),
                    if (_power.value case final status?) _status(l10n, status),
                    _configuration(l10n),
                    if (_power.value case final status?) _history(l10n, status),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _status(AppLocalizations l10n, PowerRecoveryStatus status) =>
      SettingsSection(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        header: Text(l10n.serverPowerRecoveryStatus),
        children: [
          _row(
            l10n.serverPowerRecoverySourceState,
            _sourceLabel(l10n, status.sourceState),
          ),
          _row(
            l10n.serverPowerRecoveryWorkGate,
            status.gateHeld
                ? l10n.serverPowerRecoveryHeld
                : l10n.serverPowerRecoveryOpen,
          ),
          if (status.lastObservedAt != null)
            _row(
              l10n.serverPowerRecoveryLastEvent,
              DateFormat.yMd(l10n.localeName)
                  .add_Hm()
                  .format(status.lastObservedAt!.toLocal()),
            ),
          if (status.activeRun case final run?) ...[
            _row(l10n.serverPowerRecoveryActiveRun, _runLabel(l10n, run.state)),
            if (run.failureCode != null)
              _row(l10n.serverPowerRecoveryResult, run.failureCode!),
            if (run.steps.any((step) => step.state == PowerStepState.uncertain))
              Padding(
                padding: const EdgeInsets.all(16),
                child: Semantics(
                  liveRegion: true,
                  child: Text(l10n.serverPowerRecoveryUncertain),
                ),
              ),
            if (run.state == PowerRunState.failed &&
                !run.steps.any(
                  (step) => step.state == PowerStepState.uncertain,
                ))
              CupertinoButton(
                key: const ValueKey('server-power-recovery-retry'),
                onPressed: !_power.busy
                    ? () => _power.retry(current: _capture())
                    : null,
                child: Text(l10n.serverPowerRecoveryRetry),
              ),
          ],
        ],
      );

  Widget _configuration(AppLocalizations l10n) => SettingsSection(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    header: Text(l10n.serverPowerRecoveryPolicy),
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Text(l10n.serverPowerRecoveryHint),
      ),
      _field(l10n.serverPowerRecoverySourceId, _source, 'power-source-id'),
      _field(
        l10n.serverPowerRecoverySourceToken,
        _sourceToken,
        'power-source-token',
        secret: true,
      ),
      _field(
        l10n.serverPowerRecoveryCriticalSeconds,
        _criticalSeconds,
        'power-critical-seconds',
        number: true,
      ),
      _field(
        l10n.serverPowerRecoveryStableSeconds,
        _stableSeconds,
        'power-stable-seconds',
        number: true,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(l10n.serverPowerRecoveryTargets, style: AppText.headline),
      ),
      for (var index = 0; index < _targets.length; index++)
        _target(l10n, _targets[index], index),
      CupertinoButton(
        key: const ValueKey('server-power-recovery-add-target'),
        onPressed: _targets.length < 64
            ? () => setState(
                () => _targets.add(
                  _TargetDraft(id: _id(), order: (_targets.length + 1) * 10),
                ),
              )
            : null,
        child: Text(l10n.serverPowerRecoveryAddTarget),
      ),
      if (_invalid)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Semantics(
            liveRegion: true,
            child: Text(l10n.serverPowerRecoveryInvalid),
          ),
        ),
      CupertinoButton.filled(
        key: const ValueKey('server-power-recovery-save'),
        onPressed: !_power.busy ? _save : null,
        child: Text(l10n.serverPowerRecoverySave),
      ),
      const SizedBox(height: 12),
    ],
  );

  Widget _target(AppLocalizations l10n, _TargetDraft draft, int index) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.serverPowerRecoveryTargetNumber(index + 1),
                    style: AppText.headline,
                  ),
                ),
                if (_targets.length > 1)
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => setState(() {
                      _targets.removeAt(index).dispose();
                    }),
                    child: Text(l10n.commonDelete),
                  ),
              ],
            ),
            _field(
              l10n.serverPowerRecoveryTargetLabel,
              draft.label,
              'power-label-$index',
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: CupertinoSlidingSegmentedControl<PowerTargetKind>(
                groupValue: draft.kind,
                children: {
                  PowerTargetKind.service: Text(
                    l10n.serverPowerRecoveryKindService,
                  ),
                  PowerTargetKind.proxmoxGuest: Text(
                    l10n.serverPowerRecoveryKindGuest,
                  ),
                  PowerTargetKind.networkDevice: Text(
                    l10n.serverPowerRecoveryKindNetwork,
                  ),
                  PowerTargetKind.coreHost: Text(
                    l10n.serverPowerRecoveryKindCore,
                  ),
                },
                onValueChanged: (value) {
                  if (value != null) setState(() => draft.kind = value);
                },
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: _field(
                    l10n.serverPowerRecoveryOrder,
                    draft.order,
                    'power-order-$index',
                    number: true,
                  ),
                ),
                Expanded(
                  child: _field(
                    l10n.serverPowerRecoveryTimeout,
                    draft.timeout,
                    'power-timeout-$index',
                    number: true,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(child: Text(l10n.serverPowerRecoveryStartOnRestore)),
                CupertinoSwitch(
                  value: draft.start,
                  onChanged: (value) => setState(() => draft.start = value),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _history(
    AppLocalizations l10n,
    PowerRecoveryStatus status,
  ) => SettingsSection(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    header: Text(l10n.serverPowerRecoveryHistory),
    children: status.recentRuns.isEmpty
        ? [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l10n.serverPowerRecoveryNoRuns),
            ),
          ]
        : [
            for (final run in status.recentRuns)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_runLabel(l10n, run.state), style: AppText.headline),
                    const SizedBox(height: 4),
                    Text(l10n.serverPowerRecoveryStepCount(run.steps.length)),
                    for (final step in run.steps)
                      Text(
                        '${step.sequence}. ${_stepLabel(l10n, step.action)} · ${_stepStateLabel(l10n, step.state)}',
                        style: AppText.footnote,
                      ),
                  ],
                ),
              ),
          ],
  );

  Widget _field(
    String label,
    TextEditingController controller,
    String key, {
    bool secret = false,
    bool number = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
    child: CupertinoTextField(
      key: ValueKey(key),
      controller: controller,
      placeholder: label,
      obscureText: secret,
      enableSuggestions: !secret,
      autocorrect: !secret,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      textInputAction: TextInputAction.next,
      padding: const EdgeInsets.all(12),
    ),
  );

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        Flexible(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );

  String _sourceLabel(AppLocalizations l10n, String value) => switch (value) {
    'online' => l10n.serverPowerRecoveryOnline,
    'onBattery' => l10n.serverPowerRecoveryOnBattery,
    'lowBattery' => l10n.serverPowerRecoveryLowBattery,
    _ => l10n.serverPowerRecoveryUnconfigured,
  };

  String _runLabel(AppLocalizations l10n, PowerRunState value) =>
      switch (value) {
        PowerRunState.draining => l10n.serverPowerRecoveryDraining,
        PowerRunState.shuttingDown => l10n.serverPowerRecoveryShuttingDown,
        PowerRunState.protected => l10n.serverPowerRecoveryProtected,
        PowerRunState.restoring => l10n.serverPowerRecoveryRestoring,
        PowerRunState.completed => l10n.serverPowerRecoveryCompleted,
        PowerRunState.failed => l10n.serverPowerRecoveryRunFailed,
      };

  String _stepLabel(AppLocalizations l10n, String value) => switch (value) {
    'holdNewWork' => l10n.serverPowerRecoveryHoldWork,
    'drainActiveWork' => l10n.serverPowerRecoveryDrainWork,
    'checkpointDatabase' => l10n.serverPowerRecoveryCheckpoint,
    'shutdownTarget' => l10n.serverPowerRecoveryShutdownTarget,
    'startTarget' => l10n.serverPowerRecoveryStartTarget,
    _ => l10n.serverPowerRecoveryReleaseWork,
  };

  String _stepStateLabel(AppLocalizations l10n, PowerStepState value) =>
      switch (value) {
        PowerStepState.queued => l10n.serverPowerRecoveryStepQueued,
        PowerStepState.executing => l10n.serverPowerRecoveryStepExecuting,
        PowerStepState.succeeded => l10n.serverPowerRecoveryStepSucceeded,
        PowerStepState.failed => l10n.serverPowerRecoveryStepFailed,
        PowerStepState.skipped => l10n.serverPowerRecoveryStepSkipped,
        PowerStepState.uncertain => l10n.serverPowerRecoveryStepUncertain,
      };
}
