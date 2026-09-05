import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/icon_badge.dart';
import '../../providers/settings_providers.dart';
import 'settings_nav_row.dart';
import '../../../../shared/widgets/settings_section.dart';

class SecurityPane extends ConsumerWidget {
  const SecurityPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final pin = ref.watch(pinLockProvider).value;

    return SettingsPaneScaffold(
      title: l10n.settingsCategorySecurity,
      children: [
        SettingsSection(
          footer: Text(
            pin == null ? l10n.settingsNoPinFooter : l10n.settingsPinSetFooter,
          ),
          children: [
            CupertinoListTile(
              leading: const IconBadge(
                icon: CupertinoIcons.lock_fill,
                color: CupertinoColors.systemRed,
              ),
              title: Text(
                pin == null ? l10n.settingsSetPin : l10n.settingsChangePin,
              ),
              onTap: () => _showSetPinDialog(context, ref),
            ),
            if (pin != null)
              CupertinoListTile(
                leading: const IconBadge(
                  icon: CupertinoIcons.lock_open_fill,
                  color: CupertinoColors.systemGrey,
                ),
                title: Text(l10n.settingsRemovePin),
                onTap: () => _clearPin(context, ref),
              ),
          ],
        ),
      ],
    );
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
