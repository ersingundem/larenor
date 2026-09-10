import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../../settings/providers/settings_providers.dart';
import '../data/core_ha_activity_controller.dart';
import '../data/core_ha_providers.dart';
import '../domain/core_ha_activity_models.dart';
import '../domain/core_ha_models.dart';
import 'core_ha_route.dart';
import 'core_ha_widgets.dart';

class CoreHaActivityScreen extends StatelessWidget {
  const CoreHaActivityScreen({
    super.key,
    required this.target,
    required this.verifyIntegrity,
    required this.gateCurrent,
  });

  final HomeResourceRecord target;
  final bool verifyIntegrity;
  final bool Function() gateCurrent;

  @override
  Widget build(BuildContext context) => CoreHaRoute(
    title: AppLocalizations.of(context).coreHaActivityTitle,
    gateCurrent: gateCurrent,
    backKey: 'core-ha-activity-back',
    builder: (owner) => _ActivityView(
      owner: owner,
      target: target,
      verifyIntegrity: verifyIntegrity,
    ),
  );
}

class _ActivityView extends ConsumerStatefulWidget {
  const _ActivityView({
    required this.owner,
    required this.target,
    required this.verifyIntegrity,
  });
  final CoreHaOwner owner;
  final HomeResourceRecord target;
  final bool verifyIntegrity;

  @override
  ConsumerState<_ActivityView> createState() => _ActivityViewState();
}

class _ActivityViewState extends ConsumerState<_ActivityView>
    with WidgetsBindingObserver {
  late final CoreHaActivitySelection _selection = (
    owner: widget.owner,
    target: widget.target,
    verifyIntegrity: widget.verifyIntegrity,
    checkpointProtected:
        widget.verifyIntegrity && ref.read(pinLockProvider).value != null,
  );
  late final CoreHaActivityController _controller = ref.read(
    coreHaActivityControllerProvider(_selection),
  );
  final _checkpoint = TextEditingController();
  final _reauthPin = TextEditingController();
  bool _copied = false;
  bool _checkingPin = false;
  String? _pendingCheckpointAction, _pinError;
  int _actionGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.owner.isCurrent) _controller.setVisible(true);
    });
  }

  @override
  void dispose() {
    _actionGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    _checkpoint.dispose();
    _reauthPin.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _actionGeneration++;
      _reauthPin.clear();
      if (mounted) {
        setState(() {
          _pendingCheckpointAction = null;
          _pinError = null;
          _checkingPin = false;
        });
      }
    }
  }

  bool _current() => mounted && widget.owner.isCurrent;
  String _error(String? value, AppLocalizations l) => switch (value) {
    'connection_failed' ||
    'timeout' ||
    'server_error' => l.coreHaActivityOffline,
    'forbidden' => l.coreHaActivityIntegrityForbidden,
    'conflict' || 'revision_conflict' => l.coreHaActivityCheckpointConflict,
    'invalid_request' => l.coreHaActivityCheckpointInvalid,
    _ => l.coreHaActivityFailed,
  };
  String _source(CoreHaAttributionSource value, AppLocalizations l) =>
      switch (value) {
        CoreHaAttributionSource.coreApi => l.coreHaActivitySourceCore,
        CoreHaAttributionSource.unknown => l.commonUnknown,
      };
  String _reason(CoreHaAttributionReason value, AppLocalizations l) =>
      switch (value) {
        CoreHaAttributionReason.explicitCommand =>
          l.coreHaActivityReasonExplicit,
        CoreHaAttributionReason.unknown => l.commonUnknown,
      };
  String _result(CoreHaDispatchState value, AppLocalizations l) =>
      switch (value) {
        CoreHaDispatchState.pending => l.coreHaActivityResultPending,
        CoreHaDispatchState.accepted => l.coreHaActivityResultAccepted,
        CoreHaDispatchState.rejected => l.coreHaActivityResultRejected,
        CoreHaDispatchState.unknown => l.commonUnknown,
      };

  Widget _message(String key, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Semantics(liveRegion: true, child: Text(text, key: ValueKey(key))),
  );

  Widget _line(String label, String value) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 116, child: Text(label)),
        Expanded(child: Text(value)),
      ],
    ),
  );

  void _beginCheckpointAction(String action) {
    if (!_current() || _checkingPin) return;
    _actionGeneration++;
    _reauthPin.clear();
    setState(() {
      _pendingCheckpointAction = action;
      _pinError = null;
      _copied = false;
    });
  }

  void _cancelCheckpointAction() {
    _actionGeneration++;
    _reauthPin.clear();
    setState(() {
      _pendingCheckpointAction = null;
      _pinError = null;
      _checkingPin = false;
    });
  }

  Future<void> _authorizeCheckpointAction(
    CoreHaActivityController controller,
  ) async {
    final action = _pendingCheckpointAction;
    if (!_current() || _checkingPin || action == null) return;
    final generation = _actionGeneration;
    setState(() => _checkingPin = true);
    try {
      final result = await ref
          .read(pinLockStoreProvider)
          .verify(_reauthPin.text);
      if (!mounted || !_current() || generation != _actionGeneration) return;
      _reauthPin.clear();
      if (!result.accepted) {
        final l = AppLocalizations.of(context);
        setState(() {
          _pinError = result.retryAfter > Duration.zero
              ? l.settingsGateRetryAfter(
                  (result.retryAfter.inMilliseconds / 1000).ceil(),
                )
              : l.settingsGateIncorrectPin;
        });
        return;
      }
      if (action == 'pin') {
        await controller.pinCurrentCheckpoint();
      } else if (action == 'rotate') {
        await controller.rotateTrustedCheckpoint();
      } else if (action == 'copy') {
        final value = controller.trustedCheckpoint?.exportValue;
        if (value != null && _current()) {
          await Clipboard.setData(ClipboardData(text: value));
          if (_current() && generation == _actionGeneration) _copied = true;
        }
      }
      if (_current() && generation == _actionGeneration) {
        setState(() {
          _pendingCheckpointAction = null;
          _pinError = null;
        });
      }
    } catch (_) {
      if (_current() && generation == _actionGeneration) {
        setState(
          () =>
              _pinError = AppLocalizations.of(context).settingsGateStorageError,
        );
      }
    } finally {
      if (mounted && generation == _actionGeneration) {
        setState(() => _checkingPin = false);
      }
    }
  }

  Widget _checkpointAuthorization(
    CoreHaActivityController controller,
    AppLocalizations l,
  ) {
    final action = _pendingCheckpointAction!;
    final (title, message, confirmKey) = switch (action) {
      'pin' => (
        l.coreHaCheckpointPinTitle,
        l.coreHaCheckpointPinConfirmation,
        'core-ha-checkpoint-pin-confirm',
      ),
      'rotate' => (
        l.coreHaCheckpointRotateTitle,
        l.coreHaCheckpointRotateConfirmation,
        'core-ha-checkpoint-rotate-confirm',
      ),
      _ => (
        l.coreHaCheckpointCopy,
        l.coreHaCheckpointCopyConfirmation,
        'core-ha-checkpoint-copy-confirm',
      ),
    };
    return Container(
      key: const ValueKey('core-ha-checkpoint-authorization'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
          ),
          const SizedBox(height: 8),
          Text(message),
          const SizedBox(height: 12),
          CupertinoTextField(
            key: const ValueKey('core-ha-checkpoint-reauth-pin'),
            controller: _reauthPin,
            obscureText: true,
            enabled: !_checkingPin,
            keyboardType: TextInputType.number,
            enableSuggestions: false,
            autocorrect: false,
            placeholder: l.settingsGatePinPlaceholder,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _authorizeCheckpointAction(controller),
          ),
          if (_pinError != null) ...[
            const SizedBox(height: 8),
            Text(
              _pinError!,
              key: const ValueKey('core-ha-checkpoint-pin-error'),
              style: const TextStyle(color: CupertinoColors.systemRed),
            ),
          ],
          Row(
            children: [
              Expanded(
                child: CoreHaButton(
                  key: const ValueKey('core-ha-checkpoint-action-cancel'),
                  label: l.commonCancel,
                  onPressed: !_checkingPin && _current()
                      ? _cancelCheckpointAction
                      : null,
                  isCurrent: _current,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: CoreHaButton(
                  key: ValueKey(confirmKey),
                  label: l.commonSave,
                  onPressed: !_checkingPin && _current()
                      ? () => unawaited(_authorizeCheckpointAction(controller))
                      : null,
                  isCurrent: _current,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _entry(CoreHaHistoryEntry entry, AppLocalizations l) {
    final receipt = entry.receipt;
    return Semantics(
      container: true,
      label:
          '${l.coreHaActivityActor}: ${receipt.actorId}. '
          '${l.coreHaActivityAction}: ${receipt.action == CoreHaCommandAction.turnOn ? l.coreHaTurnOn : l.coreHaTurnOff}. '
          '${l.coreHaActivitySource}: ${_source(entry.attribution.source, l)}. '
          '${l.coreHaActivityReason}: ${_reason(entry.attribution.reason, l)}. '
          '${l.coreHaActivityTime}: ${receipt.createdAt.toIso8601String()}. '
          '${l.coreHaActivityResult}: ${_result(receipt.dispatchState, l)}. '
          '${l.coreHaActivityCausalityUnknown}',
      child: Container(
        key: ValueKey('core-ha-activity-entry-${receipt.requestId}'),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
            context,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: CupertinoColors.separator.resolveFrom(context),
          ),
        ),
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _result(receipt.dispatchState, l),
                style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
              ),
              _line(l.coreHaActivityActor, receipt.actorId),
              _line(
                l.coreHaActivityAction,
                receipt.action == CoreHaCommandAction.turnOn
                    ? l.coreHaTurnOn
                    : l.coreHaTurnOff,
              ),
              _line(
                l.coreHaActivitySource,
                _source(entry.attribution.source, l),
              ),
              _line(
                l.coreHaActivityReason,
                _reason(entry.attribution.reason, l),
              ),
              _line(l.coreHaActivityTime, receipt.createdAt.toIso8601String()),
              _line(l.coreHaActivityResult, _result(receipt.dispatchState, l)),
              const SizedBox(height: 8),
              Text(l.coreHaActivityCausalityUnknown),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _integrity(CoreHaActivityController c, AppLocalizations l) {
    if (!widget.verifyIntegrity) {
      return [
        Text(
          l.coreHaActivityIntegrityAdminOnly,
          key: const ValueKey('core-ha-integrity-admin-only'),
        ),
      ];
    }
    final proof = c.verification;
    return [
      if (!c.checkpointProtected)
        Text(
          l.coreHaCheckpointPinRequired,
          key: const ValueKey('core-ha-checkpoint-pin-required'),
        ),
      if (c.checkpointProtected && c.checkpointLoaded) ...[
        if (c.trustedCheckpoint == null)
          Text(
            l.coreHaCheckpointUnpinned,
            key: const ValueKey('core-ha-checkpoint-unpinned'),
          )
        else ...[
          Text(
            l.coreHaCheckpointPinned,
            key: const ValueKey('core-ha-checkpoint-pinned'),
          ),
          _line(
            l.coreHaCheckpointPinnedAt,
            c.trustedCheckpoint!.pinnedAt.toIso8601String(),
          ),
          _line(l.coreHaActivitySequence, '${c.trustedCheckpoint!.sequence}'),
          if (c.trustedCompared)
            Text(
              l.coreHaCheckpointAutoMatched,
              key: const ValueKey('core-ha-checkpoint-auto-matched'),
            ),
        ],
      ],
      if (c.checkpointAlarm != null)
        Semantics(
          liveRegion: true,
          child: Text(
            c.checkpointAlarm == 'rollback'
                ? l.coreHaCheckpointRollbackAlarm
                : l.coreHaCheckpointMismatchAlarm,
            key: const ValueKey('core-ha-checkpoint-alarm'),
            style: const TextStyle(color: CupertinoColors.systemRed),
          ),
        ),
      if (c.checkpointFailure != null)
        _message(
          'core-ha-checkpoint-storage-error',
          l.coreHaCheckpointStorageFailed,
        ),
      if (proof != null) ...[
        Text(
          l.coreHaActivityIntegrityVerified,
          key: const ValueKey('core-ha-integrity-verified'),
          style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
        ),
        const SizedBox(height: 8),
        Text(
          proof.comparedCheckpoint
              ? l.coreHaActivityCheckpointMatched
              : l.coreHaActivityCheckpointNotCompared,
          key: ValueKey(
            proof.comparedCheckpoint
                ? 'core-ha-checkpoint-matched'
                : 'core-ha-checkpoint-current',
          ),
        ),
        _line(l.coreHaActivitySequence, '${proof.sequence}'),
        _line(l.coreHaActivityHead, proof.headHash),
        _line(l.coreHaActivityCheckpoint, proof.checkpoint),
        const SizedBox(height: 8),
        Text(l.coreHaActivityCausalityUnknown),
      ],
      if (c.canPinCheckpoint)
        CoreHaButton(
          key: const ValueKey('core-ha-checkpoint-pin'),
          label: l.coreHaCheckpointPinAction,
          onPressed: _current() ? () => _beginCheckpointAction('pin') : null,
          isCurrent: _current,
        ),
      if (c.trustedCheckpoint != null) ...[
        CoreHaButton(
          key: const ValueKey('core-ha-checkpoint-copy'),
          label: l.coreHaCheckpointCopy,
          onPressed: _current() ? () => _beginCheckpointAction('copy') : null,
          isCurrent: _current,
        ),
        if (_copied)
          _message('core-ha-checkpoint-copied', l.coreHaCheckpointCopied),
      ],
      if (c.canRotateCheckpoint)
        CoreHaButton(
          key: const ValueKey('core-ha-checkpoint-rotate'),
          label: l.coreHaCheckpointRotateAction,
          onPressed: _current() ? () => _beginCheckpointAction('rotate') : null,
          isCurrent: _current,
        ),
      if (c.integrityFailure != null)
        _message('core-ha-integrity-error', _error(c.integrityFailure, l)),
      if (_pendingCheckpointAction != null) _checkpointAuthorization(c, l),
      const SizedBox(height: 12),
      CupertinoTextField(
        key: const ValueKey('core-ha-checkpoint-input'),
        placeholder: l.coreHaActivityCheckpointInput,
        controller: _checkpoint,
        enabled: c.canVerifyCheckpoint,
        maxLength: 512,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.done,
        padding: const EdgeInsets.all(14),
        onSubmitted: (_) {
          if (_current()) {
            unawaited(c.compareCheckpoint(_checkpoint.text));
          }
        },
      ),
      CoreHaButton(
        key: const ValueKey('core-ha-checkpoint-verify'),
        label: l.coreHaActivityVerifyCheckpoint,
        onPressed: c.canVerifyCheckpoint && _current()
            ? () => unawaited(c.compareCheckpoint(_checkpoint.text))
            : null,
        isCurrent: _current,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(coreHaActivityControllerProvider(_selection));
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: _controller,
      builder: (_, _) {
        final c = _controller;
        return CoreHaPage(
          key: const ValueKey('core-ha-activity'),
          title: l.coreHaActivityTitle,
          backKey: 'core-ha-activity-back',
          onBack: _current() ? () => Navigator.of(context).maybePop() : null,
          slivers: [
            coreHaBlock([
              CoreHaButton(
                key: const ValueKey('core-ha-activity-refresh'),
                label: l.commonRefresh,
                onPressed: c.canRefresh && _current()
                    ? () => unawaited(c.refresh())
                    : null,
                isCurrent: _current,
              ),
              if (c.busy) _message('core-ha-activity-loading', l.coreHaLoading),
              if (c.failure != null)
                _message(
                  c.stale ? 'core-ha-activity-stale' : 'core-ha-activity-error',
                  c.stale &&
                          {
                            'connection_failed',
                            'timeout',
                            'server_error',
                          }.contains(c.failure)
                      ? l.coreHaActivityRetainedOffline
                      : _error(c.failure, l),
                ),
            ]),
            coreHaBlock([
              Semantics(
                header: true,
                child: Text(
                  l.coreHaActivityIntegrity,
                  style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
                ),
              ),
              const SizedBox(height: 8),
              ..._integrity(c, l),
            ]),
            coreHaBlock([
              Semantics(
                header: true,
                child: Text(
                  l.coreHaActivityEntries,
                  style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
                ),
              ),
              const SizedBox(height: 12),
              if (c.loaded && c.entries.isEmpty)
                Text(
                  l.coreHaActivityEmpty,
                  key: const ValueKey('core-ha-activity-empty'),
                ),
              for (final entry in c.entries) _entry(entry, l),
              if (c.truncated) Text(l.coreHaActivityLimit),
              if (c.canLoadMore)
                CoreHaButton(
                  key: const ValueKey('core-ha-activity-more'),
                  label: l.coreHaActivityLoadMore,
                  onPressed: _current() ? () => unawaited(c.loadMore()) : null,
                  isCurrent: _current,
                ),
            ]),
          ],
        );
      },
    );
  }
}
