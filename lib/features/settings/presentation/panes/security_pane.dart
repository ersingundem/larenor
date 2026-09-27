import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/icon_badge.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../core_audit/data/core_audit_controller.dart';
import '../../../core_audit/data/core_audit_providers.dart';
import '../../providers/settings_providers.dart';
import '../settings_file_dialog.dart';
import 'settings_nav_row.dart';

class SecurityPane extends ConsumerWidget {
  const SecurityPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final pin = ref.watch(pinLockProvider).value;
    final coreAudit = ref.watch(coreAuditControllerProvider);
    final interaction = AppInteractionScope.maybeRead(context);
    final epoch = interaction?.epoch;
    bool current() =>
        context.mounted &&
        interaction?.active != false &&
        interaction?.epoch == epoch &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent == true;

    return SettingsPaneScaffold(
      title: l10n.settingsCategorySecurity,
      children: [
        SettingsSection(
          header: Semantics(
            key: const ValueKey('security-settings-header'),
            header: true,
            child: Text(l10n.settingsCategorySecurity),
          ),
          footer: Text(
            pin == null ? l10n.settingsNoPinFooter : l10n.settingsPinSetFooter,
          ),
          children: [
            SettingsActionTile(
              buttonKey: const ValueKey('security-pin-action'),
              leading: const IconBadge(
                icon: CupertinoIcons.lock_fill,
                color: CupertinoColors.systemRed,
              ),
              title: Text(
                pin == null ? l10n.settingsSetPin : l10n.settingsChangePin,
              ),
              onTap: current()
                  ? () {
                      if (current()) _showSetPinDialog(context, ref);
                    }
                  : null,
            ),
            if (pin != null)
              SettingsActionTile(
                buttonKey: const ValueKey('security-remove-pin-action'),
                leading: const IconBadge(
                  icon: CupertinoIcons.lock_open_fill,
                  color: CupertinoColors.systemGrey,
                ),
                title: Text(l10n.settingsRemovePin),
                onTap: current()
                    ? () {
                        if (current()) _clearPin(context, ref);
                      }
                    : null,
              ),
          ],
        ),
        ListenableBuilder(
          listenable: coreAudit,
          builder: (context, _) => SettingsSection(
            header: Semantics(
              key: const ValueKey('core-audit-settings-header'),
              header: true,
              child: Text(l10n.coreAuditTitle),
            ),
            footer: _CoreAuditStatus(
              controller: coreAudit,
              hasSettingsPin: pin != null,
            ),
            children: [
              SettingsActionTile(
                buttonKey: const ValueKey('core-audit-compare-action'),
                leading: const IconBadge(
                  icon: CupertinoIcons.shield_lefthalf_fill,
                  color: CupertinoColors.systemBlue,
                ),
                title: Text(l10n.coreAuditCompare),
                additionalInfo: Text(_coreAuditSummary(l10n, coreAudit)),
                onTap: current() && coreAudit.canRefresh
                    ? () {
                        if (current()) unawaited(coreAudit.refresh());
                      }
                    : null,
              ),
              if (coreAudit.canPin)
                SettingsActionTile(
                  buttonKey: const ValueKey('core-audit-pin-action'),
                  leading: const IconBadge(
                    icon: CupertinoIcons.pin_fill,
                    color: CupertinoColors.systemGreen,
                  ),
                  title: Text(l10n.coreAuditPinAction),
                  onTap: current() && pin != null
                      ? () => unawaited(
                          _authorizeCheckpointAction(
                            context,
                            ref,
                            coreAudit,
                            rotate: false,
                          ),
                        )
                      : null,
                ),
              if (coreAudit.canRotate)
                SettingsActionTile(
                  buttonKey: const ValueKey('core-audit-rotate-action'),
                  leading: const IconBadge(
                    icon: CupertinoIcons.arrow_2_circlepath,
                    color: CupertinoColors.systemOrange,
                  ),
                  title: Text(l10n.coreAuditRotateAction),
                  onTap: current() && pin != null
                      ? () => unawaited(
                          _authorizeCheckpointAction(
                            context,
                            ref,
                            coreAudit,
                            rotate: true,
                          ),
                        )
                      : null,
                ),
            ],
          ),
        ),
      ],
    );
  }

  static String _coreAuditSummary(
    AppLocalizations l10n,
    CoreAuditController controller,
  ) {
    if (!controller.available) return l10n.coreAuditUnavailable;
    if (controller.busy || !controller.loaded) return l10n.coreAuditChecking;
    if (controller.checkpointAlarm == 'rollback') {
      return l10n.coreAuditRollbackAlarm;
    }
    if (controller.checkpointAlarm != null) {
      return l10n.coreAuditMismatchAlarm;
    }
    if (controller.checkpointFailure != null) {
      return l10n.coreAuditStorageFailed;
    }
    if (controller.failure != null || controller.verification == null) {
      return l10n.coreAuditRequestFailed;
    }
    if (controller.trustedCheckpoint == null) {
      return '${l10n.coreAuditVerified} ${l10n.coreAuditUnpinned}';
    }
    return controller.trustedCompared
        ? '${l10n.coreAuditVerified} ${l10n.coreAuditMatched}'
        : l10n.coreAuditPinned;
  }

  Future<void> _authorizeCheckpointAction(
    BuildContext context,
    WidgetRef ref,
    CoreAuditController controller, {
    required bool rotate,
  }) async {
    if (!context.mounted) return;
    final interaction = AppInteractionScope.maybeRead(context);
    final epoch = interaction?.epoch;
    bool current() =>
        context.mounted &&
        interaction?.active != false &&
        interaction?.epoch == epoch &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent == true;
    if (!current() || (rotate ? !controller.canRotate : !controller.canPin)) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(
          rotate
              ? l10n.coreHaCheckpointRotateTitle
              : l10n.coreHaCheckpointPinTitle,
        ),
        content: Text(
          rotate
              ? l10n.coreHaCheckpointRotateConfirmation
              : l10n.coreHaCheckpointPinConfirmation,
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              rotate ? l10n.coreAuditRotateAction : l10n.coreAuditPinAction,
            ),
          ),
        ],
      ),
    );
    if (!context.mounted || !current() || confirmed != true) return;
    final authorized = await reauthenticateSettingsFileDialog(
      context,
      ref.read(pinLockStoreProvider),
    );
    if (!current() || !authorized) return;
    if (rotate) {
      await controller.rotateTrusted();
    } else {
      await controller.pinCurrent();
    }
  }

  Future<void> _clearPin(BuildContext context, WidgetRef ref) async {
    if (!context.mounted ||
        AppInteractionScope.maybeRead(context)?.active == false) {
      return;
    }
    try {
      await ref.read(pinLockProvider.notifier).clearPin();
    } catch (_) {
      if (!context.mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        useRootNavigator: false,
        builder: (context) => CupertinoAlertDialog(
          content: Text(AppLocalizations.of(context).settingsPinSaveError),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context),
              child: Text(AppLocalizations.of(context).commonClose),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _showSetPinDialog(BuildContext context, WidgetRef ref) async {
    if (!context.mounted ||
        AppInteractionScope.maybeRead(context)?.active == false) {
      return;
    }
    await showCupertinoDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (_) => const _PinDialog(),
    );
  }
}

class _CoreAuditStatus extends StatelessWidget {
  const _CoreAuditStatus({
    required this.controller,
    required this.hasSettingsPin,
  });

  final CoreAuditController controller;
  final bool hasSettingsPin;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final alarm =
        controller.checkpointAlarm != null ||
        controller.checkpointFailure != null;
    return Semantics(
      key: const ValueKey('core-audit-status'),
      liveRegion: true,
      child: Text(
        hasSettingsPin || !controller.available
            ? SecurityPane._coreAuditSummary(l10n, controller)
            : '${SecurityPane._coreAuditSummary(l10n, controller)} '
                  '${l10n.coreAuditPinRequired}',
        style: alarm
            ? TextStyle(color: CupertinoColors.systemRed.resolveFrom(context))
            : null,
      ),
    );
  }
}

class _PinDialog extends ConsumerStatefulWidget {
  const _PinDialog();

  @override
  ConsumerState<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends ConsumerState<_PinDialog> {
  final _controller = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!mounted ||
        _saving ||
        AppInteractionScope.maybeRead(context)?.active == false) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final pin = _controller.text.trim();
    if (!RegExp(r'^\d{4,12}$').hasMatch(pin)) {
      setState(() => _error = l10n.settingsPinInvalid);
      return;
    }
    final route = ModalRoute.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(pinLockProvider.notifier).setPin(pin);
      if (mounted && route?.isCurrent == true) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _error = l10n.settingsPinSaveError);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: !_saving,
      child: CupertinoAlertDialog(
        title: Text(l10n.settingsSetPinTitle),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            children: [
              CupertinoTextField(
                controller: _controller,
                keyboardType: TextInputType.number,
                obscureText: true,
                autofocus: true,
                enableSuggestions: false,
                autocorrect: false,
                enabled: !_saving,
                placeholder: l10n.settingsPinPlaceholder,
                onSubmitted: (_) => _save(),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: CupertinoColors.systemRed.resolveFrom(context),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          CupertinoDialogAction(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const CupertinoActivityIndicator()
                : Text(l10n.commonSave),
          ),
        ],
      ),
    );
  }
}
