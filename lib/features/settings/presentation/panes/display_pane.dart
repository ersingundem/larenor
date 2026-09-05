import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/icon_badge.dart';
import '../../providers/settings_providers.dart';
import 'settings_nav_row.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../media/local_audio/presentation/playback_power_screen.dart';

class DisplayPane extends ConsumerWidget {
  const DisplayPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final keepScreenOn = ref.watch(keepScreenOnProvider);
    final nightWindow = ref.watch(nightWindowProvider).value;
    final idleMode = ref.watch(idleModeProvider).value;
    final appearance =
        ref.watch(appearanceProvider).value ?? AppAppearance.system;

    return SettingsPaneScaffold(
      title: l10n.settingsCategoryDisplay,
      children: [
        SettingsSection(
          header: Text(l10n.settingsSectionDisplay),
          children: [
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
        if (nightWindow != null)
          SettingsSection(
            header: Text(l10n.settingsSectionNightMode),
            footer: Text(l10n.settingsNightModeFooter),
            children: [
              CupertinoListTile(
                title: Text(l10n.settingsNightStarts),
                additionalInfo: Text(_formatMinutes(nightWindow.startMinutes)),
                trailing: const CupertinoListTileChevron(),
                onTap: () => _pickTime(
                  context,
                  initialMinutes: nightWindow.startMinutes,
                  onPicked: (minutes) => ref
                      .read(nightWindowProvider.notifier)
                      .setStartMinutes(minutes),
                ),
              ),
              CupertinoListTile(
                title: Text(l10n.settingsNightEnds),
                additionalInfo: Text(_formatMinutes(nightWindow.endMinutes)),
                trailing: const CupertinoListTileChevron(),
                onTap: () => _pickTime(
                  context,
                  initialMinutes: nightWindow.endMinutes,
                  onPicked: (minutes) => ref
                      .read(nightWindowProvider.notifier)
                      .setEndMinutes(minutes),
                ),
              ),
              CupertinoListTile(
                title: Text(l10n.settingsNightDim),
                trailing: CupertinoSwitch(
                  value: nightWindow.dimBrightnessAtNight,
                  onChanged: (value) => ref
                      .read(nightWindowProvider.notifier)
                      .setDimBrightnessAtNight(value),
                ),
              ),
              CupertinoListTile(
                title: Text(l10n.settingsNightScreenOff),
                subtitle: Text(l10n.settingsNightScreenOffHint),
                trailing: CupertinoSwitch(
                  value: nightWindow.screenOffAtNight,
                  onChanged: (value) => ref
                      .read(nightWindowProvider.notifier)
                      .setScreenOffAtNight(value),
                ),
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
    final l10n = AppLocalizations.of(context);
    final choice = await showCupertinoModalPopup<AppAppearance>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.settingsAppearance),
        message: Text(l10n.settingsAppearanceSystemHint),
        actions: [
          for (final option in AppAppearance.values)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(sheetContext, option),
              child: Text(
                _appearanceLabel(l10n, option),
                style: option == current
                    ? const TextStyle(fontWeight: FontWeight.w600)
                    : null,
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheetContext),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
    if (choice != null) {
      await ref.read(appearanceProvider.notifier).set(choice);
    }
  }

  String _formatMinutes(int minutes) {
    final hour = (minutes ~/ 60).toString().padLeft(2, '0');
    final minute = (minutes % 60).toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Future<void> _pickTime(
    BuildContext context, {
    required int initialMinutes,
    required ValueChanged<int> onPicked,
  }) async {
    var selected = initialMinutes;
    final now = DateTime.now();
    final initial = DateTime(
      now.year,
      now.month,
      now.day,
      initialMinutes ~/ 60,
      initialMinutes % 60,
    );

    await showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => Container(
        height: 260,
        color: CupertinoColors.systemBackground.resolveFrom(context),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                CupertinoButton(
                  child: Text(AppLocalizations.of(context).commonDone),
                  onPressed: () {
                    onPicked(selected);
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.time,
                initialDateTime: initial,
                use24hFormat: true,
                onDateTimeChanged: (value) =>
                    selected = value.hour * 60 + value.minute,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showTimeoutPicker(BuildContext context, WidgetRef ref) async {
    const options = [1, 2, 5, 10, 15, 30];
    final choice = await showCupertinoModalPopup<int>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(AppLocalizations.of(context).settingsIdleAfterTitle),
        actions: [
          for (final minutes in options)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, minutes),
              child: Text(
                AppLocalizations.of(context).settingsMinutesShort(minutes),
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
      ),
    );
    if (choice != null) {
      await ref.read(idleModeProvider.notifier).setTimeoutMinutes(choice);
    }
  }
}
