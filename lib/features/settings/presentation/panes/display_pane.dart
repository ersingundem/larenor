import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../../core/theme.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/icon_badge.dart';
import '../../providers/settings_providers.dart';
import 'settings_nav_row.dart';
import '../settings_file_dialog.dart';
import '../../../ambient/presentation/ambient_settings_screen.dart';
import '../../../kiosk/presentation/kiosk_screen.dart';
import '../../../web_panel/presentation/web_panel_data_screen.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../media/local_audio/presentation/playback_power_screen.dart';
import '../window_panel_screen.dart';
import '../screen_program_screen.dart';

class DisplayPane extends ConsumerWidget {
  const DisplayPane({super.key, this.runFileDialog});

  final SettingsFileDialogRunner? runFileDialog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final keepScreenOn = ref.watch(keepScreenOnProvider);
    final idleMode = ref.watch(idleModeProvider).value;
    final appearance =
        ref.watch(appearanceProvider).value ?? AppAppearance.system;

    return SettingsPaneScaffold(
      title: l10n.settingsCategoryDisplay,
      children: [
        SettingsSection(
          header: Text(l10n.settingsSectionDisplay),
          children: [
            SettingsNavRow(
              icon: CupertinoIcons.photo_on_rectangle,
              color: CupertinoColors.systemOrange,
              title: l10n.ambientTitle,
              builder: (_) =>
                  AmbientSettingsScreen(runFileDialog: runFileDialog),
            ),
            SettingsNavRow(
              icon: CupertinoIcons.globe,
              color: CupertinoColors.systemBlue,
              title: l10n.webPanelDataTitle,
              builder: (_) => const WebPanelDataScreen(),
            ),
            SettingsNavRow(
              icon: CupertinoIcons.rectangle_on_rectangle,
              color: CupertinoColors.systemTeal,
              title: l10n.windowTitle,
              builder: (_) => const WindowPanelScreen(),
            ),
            SettingsNavRow(
              icon: CupertinoIcons.lock_shield,
              color: CupertinoColors.systemIndigo,
              title: l10n.kioskTitle,
              builder: (_) => const KioskScreen(),
            ),
            CupertinoListTile(
              leading: const IconBadge(
                icon: CupertinoIcons.music_note_2,
                color: CupertinoColors.systemPurple,
              ),
              title: Text(l10n.localAudioPowerTitle),
              trailing: const CupertinoListTileChevron(),
              onTap: () => Navigator.of(context).push(
                CupertinoPageRoute<void>(
                  builder: (_) => const PlaybackPowerScreen(),
                ),
              ),
            ),
            CupertinoListTile(
              leading: const IconBadge(
                icon: CupertinoIcons.circle_lefthalf_fill,
                color: CupertinoColors.systemIndigo,
              ),
              title: Text(l10n.settingsAppearance),
              additionalInfo: Text(_appearanceLabel(l10n, appearance)),
              trailing: const CupertinoListTileChevron(),
              onTap: () => _showAppearancePicker(context, ref, appearance),
            ),
            CupertinoListTile(
              leading: const IconBadge(
                icon: CupertinoIcons.brightness,
                color: CupertinoColors.systemYellow,
              ),
              title: Text(l10n.settingsKeepScreenOn),
              subtitle: Text(l10n.settingsKeepScreenOnHint),
              trailing: CupertinoSwitch(
                value: keepScreenOn.value ?? false,
                onChanged: (value) =>
                    ref.read(keepScreenOnProvider.notifier).set(value),
              ),
            ),
            if (idleMode != null) ...[
              CupertinoListTile(
                leading: const IconBadge(
                  icon: CupertinoIcons.moon_stars,
                  color: CupertinoColors.systemIndigo,
                ),
                title: Text(l10n.settingsIdleMode),
                subtitle: Text(l10n.settingsIdleModeHint),
                trailing: CupertinoSwitch(
                  value: idleMode.enabled,
                  onChanged: (value) =>
                      ref.read(idleModeProvider.notifier).setEnabled(value),
                ),
              ),
              if (idleMode.enabled)
                CupertinoListTile(
                  title: Text(l10n.settingsIdleModeAfter),
                  additionalInfo: Text(
                    l10n.settingsMinutesShort(idleMode.timeoutMinutes),
                  ),
                  trailing: const CupertinoListTileChevron(),
                  onTap: () => _showTimeoutPicker(context, ref),
                ),
            ],
          ],
        ),
        SettingsSection(
          footer: Text(l10n.screenProgramDefault),
          children: [
            SettingsNavRow(
              icon: CupertinoIcons.calendar,
              color: CupertinoColors.systemIndigo,
              title: l10n.screenProgramTitle,
              builder: (_) => const ScreenProgramScreen(),
            ),
          ],
        ),
      ],
    );
  }

  String _appearanceLabel(AppLocalizations l10n, AppAppearance appearance) =>
      switch (appearance) {
        AppAppearance.system => l10n.settingsAppearanceSystem,
        AppAppearance.light => l10n.settingsAppearanceLight,
        AppAppearance.dark => l10n.settingsAppearanceDark,
      };

  Future<void> _showAppearancePicker(
    BuildContext context,
    WidgetRef ref,
    AppAppearance current,
  ) async {
    if (!context.mounted) return;
    final interaction = AppInteractionScope.maybeRead(context);
    final epoch = interaction?.epoch;
    bool interactionCurrent() =>
        context.mounted &&
        interaction?.active != false &&
        epoch == interaction?.epoch;
    if (!interactionCurrent()) return;
    final l10n = AppLocalizations.of(context);
    final choice = await showCupertinoModalPopup<AppAppearance>(
      context: context,
      useRootNavigator: false,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.settingsAppearance),
        message: Text(l10n.settingsAppearanceSystemHint),
        actions: [
          for (final option in AppAppearance.values)
            CupertinoActionSheetAction(
              onPressed: () {
                if (interactionCurrent() &&
                    sheetContext.mounted &&
                    ModalRoute.of(sheetContext)?.isCurrent == true) {
                  Navigator.pop(sheetContext, option);
                }
              },
              child: Text(
                _appearanceLabel(l10n, option),
                style: option == current
                    ? const TextStyle(fontWeight: FontWeight.w600)
                    : null,
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () {
            if (sheetContext.mounted &&
                ModalRoute.of(sheetContext)?.isCurrent == true) {
              Navigator.pop(sheetContext);
            }
          },
          child: Text(l10n.commonCancel),
        ),
      ),
    );
    if (choice != null && interactionCurrent()) {
      await ref.read(appearanceProvider.notifier).set(choice);
    }
  }

  Future<void> _showTimeoutPicker(BuildContext context, WidgetRef ref) async {
    if (!context.mounted) return;
    final interaction = AppInteractionScope.maybeRead(context);
    final epoch = interaction?.epoch;
    bool interactionCurrent() =>
        context.mounted &&
        interaction?.active != false &&
        epoch == interaction?.epoch;
    if (!interactionCurrent()) return;
    const options = [1, 2, 5, 10, 15, 30];
    final choice = await showCupertinoModalPopup<int>(
      context: context,
      useRootNavigator: false,
      builder: (context) => CupertinoActionSheet(
        title: Text(AppLocalizations.of(context).settingsIdleAfterTitle),
        actions: [
          for (final minutes in options)
            CupertinoActionSheetAction(
              onPressed: () {
                if (interactionCurrent() &&
                    context.mounted &&
                    ModalRoute.of(context)?.isCurrent == true) {
                  Navigator.pop(context, minutes);
                }
              },
              child: Text(
                AppLocalizations.of(context).settingsMinutesShort(minutes),
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () {
            if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
              Navigator.pop(context);
            }
          },
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
      ),
    );
    if (choice != null && interactionCurrent()) {
      await ref.read(idleModeProvider.notifier).setTimeoutMinutes(choice);
    }
  }
}
