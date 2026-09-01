import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/icon_badge.dart';
import '../../providers/settings_providers.dart';
import 'settings_nav_row.dart';

class SecurityPane extends ConsumerWidget {
  const SecurityPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final pin = ref.watch(pinLockProvider).value;

    return SettingsPaneScaffold(
      title: l10n.settingsCategorySecurity,
      children: [
        CupertinoListSection.insetGrouped(
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
                onTap: () => ref.read(pinLockProvider.notifier).clearPin(),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _showSetPinDialog(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final pin = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(AppLocalizations.of(context).settingsSetPinTitle),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: controller,
            keyboardType: TextInputType.number,
            obscureText: true,
            autofocus: true,
            placeholder: AppLocalizations.of(context).settingsPinPlaceholder,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context).commonCancel),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(AppLocalizations.of(context).commonSave),
          ),
        ],
      ),
    );

    if (pin == null || pin.length < 4) return;
    await ref.read(pinLockProvider.notifier).setPin(pin);
  }
}
