import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/presentation/areas_screen.dart';
import '../../admin/presentation/automations_screen.dart';
import '../../admin/presentation/cameras_screen.dart';
import '../../admin/presentation/devices_screen.dart';
import '../../admin/presentation/entities_screen.dart';
import '../../admin/presentation/integrations_screen.dart';
import '../../auth/providers/auth_providers.dart';
import '../../media/arr/presentation/radarr_screen.dart';
import '../../media/arr/presentation/sonarr_screen.dart';
import '../../media/jellyfin/presentation/jellyfin_home_screen.dart';
import '../../media/jellyseerr/presentation/jellyseerr_home_screen.dart';
import '../../media/qbittorrent/presentation/qbittorrent_torrents_screen.dart';
import '../providers/settings_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(connectionConfigProvider).value;
    final keepScreenOn = ref.watch(keepScreenOnProvider);
    final nightWindow = ref.watch(nightWindowProvider).value;
    final pin = ref.watch(pinLockProvider).value;
    final idleMode = ref.watch(idleModeProvider).value;

    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Settings')),
      child: SafeArea(
        child: ListView(
          children: [
            const SizedBox(height: 16),
            CupertinoListSection.insetGrouped(
              header: const Text('CONNECTION'),
              children: [
                CupertinoListTile(
                  leading: const Icon(CupertinoIcons.house),
                  title: const Text('Home Assistant server'),
                  additionalInfo: Text(config?.baseUrl ?? 'Not connected'),
                ),
              ],
            ),
            CupertinoListSection.insetGrouped(
              header: const Text('DISPLAY'),
              children: [
                CupertinoListTile(
                  leading: const Icon(CupertinoIcons.brightness),
                  title: const Text('Keep screen on'),
                  subtitle: const Text('Recommended for wall-mounted tablets'),
                  trailing: CupertinoSwitch(
                    value: keepScreenOn.value ?? false,
                    onChanged: (value) =>
                        ref.read(keepScreenOnProvider.notifier).set(value),
                  ),
                ),
                if (idleMode != null) ...[
                  CupertinoListTile(
                    leading: const Icon(CupertinoIcons.moon_stars),
                    title: const Text('Idle/ambient mode'),
                    subtitle: const Text(
                      'Show a clock screen after inactivity',
                    ),
                    trailing: CupertinoSwitch(
                      value: idleMode.enabled,
                      onChanged: (value) =>
                          ref.read(idleModeProvider.notifier).setEnabled(value),
                    ),
                  ),
                  if (idleMode.enabled)
                    CupertinoListTile(
                      title: const Text('After'),
                      additionalInfo: Text('${idleMode.timeoutMinutes} min'),
                      trailing: const CupertinoListTileChevron(),
                      onTap: () => _showTimeoutPicker(context, ref, idleMode),
                    ),
                ],
              ],
            ),
            if (nightWindow != null)
              CupertinoListSection.insetGrouped(
                header: const Text('NIGHT MODE'),
                footer: const Text(
                  'A shared overnight window used to dim the screen and/or '
                  'let it turn off, like a day/night theme.',
                ),
                children: [
                  CupertinoListTile(
                    title: const Text('Starts'),
                    additionalInfo: Text(
                      _formatMinutes(nightWindow.startMinutes),
                    ),
                    trailing: const CupertinoListTileChevron(),
                    onTap: () => _pickTime(
                      context,
                      ref,
                      initialMinutes: nightWindow.startMinutes,
                      onPicked: (minutes) => ref
                          .read(nightWindowProvider.notifier)
                          .setStartMinutes(minutes),
                    ),
                  ),
                  CupertinoListTile(
                    title: const Text('Ends'),
                    additionalInfo: Text(
                      _formatMinutes(nightWindow.endMinutes),
                    ),
                    trailing: const CupertinoListTileChevron(),
                    onTap: () => _pickTime(
                      context,
                      ref,
                      initialMinutes: nightWindow.endMinutes,
                      onPicked: (minutes) => ref
                          .read(nightWindowProvider.notifier)
                          .setEndMinutes(minutes),
                    ),
                  ),
                  CupertinoListTile(
                    title: const Text('Dim screen at night'),
                    trailing: CupertinoSwitch(
                      value: nightWindow.dimBrightnessAtNight,
                      onChanged: (value) => ref
                          .read(nightWindowProvider.notifier)
                          .setDimBrightnessAtNight(value),
                    ),
                  ),
                  CupertinoListTile(
                    title: const Text('Turn screen off at night'),
                    subtitle: const Text(
                      'Overrides "Keep screen on" overnight',
                    ),
                    trailing: CupertinoSwitch(
                      value: nightWindow.screenOffAtNight,
                      onChanged: (value) => ref
                          .read(nightWindowProvider.notifier)
                          .setScreenOffAtNight(value),
                    ),
                  ),
                ],
              ),
            CupertinoListSection.insetGrouped(
              header: const Text('SECURITY'),
              footer: Text(
                pin == null
                    ? 'No PIN set — Settings is open to anyone using this device.'
                    : 'Settings is locked behind a PIN.',
              ),
              children: [
                CupertinoListTile(
                  leading: const Icon(CupertinoIcons.lock),
                  title: Text(pin == null ? 'Set PIN' : 'Change PIN'),
                  onTap: () => _showSetPinDialog(context, ref),
                ),
                if (pin != null)
                  CupertinoListTile(
                    leading: const Icon(CupertinoIcons.lock_open),
                    title: const Text('Remove PIN'),
                    onTap: () => ref.read(pinLockProvider.notifier).clearPin(),
                  ),
              ],
            ),
            CupertinoListSection.insetGrouped(
              header: const Text('MANAGE HOME ASSISTANT'),
              children: [
                _AdminRow(
                  icon: CupertinoIcons.cube_box,
                  title: 'Integrations',
                  builder: (_) => const IntegrationsScreen(),
                ),
                _AdminRow(
                  icon: CupertinoIcons.device_laptop,
                  title: 'Devices',
                  builder: (_) => const DevicesScreen(),
                ),
                _AdminRow(
                  icon: CupertinoIcons.square_grid_2x2,
                  title: 'Areas',
                  builder: (_) => const AreasScreen(),
                ),
                _AdminRow(
                  icon: CupertinoIcons.list_bullet,
                  title: 'Entities',
                  builder: (_) => const EntitiesScreen(),
                ),
                _AdminRow(
                  icon: CupertinoIcons.bolt,
                  title: 'Automations',
                  builder: (_) => const AutomationsScreen(),
                ),
                _AdminRow(
                  icon: CupertinoIcons.videocam,
                  title: 'Cameras',
                  builder: (_) => const CamerasScreen(),
                ),
              ],
            ),
            CupertinoListSection.insetGrouped(
              header: const Text('MEDIA SERVICES'),
              footer: const Text(
                'Each service is independent — connect the ones you use.',
              ),
              children: [
                _AdminRow(
                  icon: CupertinoIcons.play_rectangle,
                  title: 'Jellyfin',
                  builder: (_) => const JellyfinHomeScreen(),
                ),
                _AdminRow(
                  icon: CupertinoIcons.search,
                  title: 'Jellyseerr',
                  builder: (_) => const JellyseerrHomeScreen(),
                ),
                _AdminRow(
                  icon: CupertinoIcons.tv,
                  title: 'Sonarr',
                  builder: (_) => const SonarrScreen(),
                ),
                _AdminRow(
                  icon: CupertinoIcons.film,
                  title: 'Radarr',
                  builder: (_) => const RadarrScreen(),
                ),
                _AdminRow(
                  icon: CupertinoIcons.arrow_down_circle,
                  title: 'qBittorrent',
                  builder: (_) => const QbittorrentTorrentsScreen(),
                ),
              ],
            ),
            CupertinoListSection.insetGrouped(
              children: [
                CupertinoListTile(
                  title: Center(
                    child: Text(
                      'Sign out',
                      style: TextStyle(
                        color: CupertinoColors.systemRed.resolveFrom(context),
                      ),
                    ),
                  ),
                  onTap: () async {
                    await ref.read(connectionConfigProvider.notifier).signOut();
                    if (context.mounted) context.go('/');
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatMinutes(int minutes) {
    final hour = (minutes ~/ 60).toString().padLeft(2, '0');
    final minute = (minutes % 60).toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Future<void> _pickTime(
    BuildContext context,
    WidgetRef ref, {
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
                  child: const Text('Done'),
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

  Future<void> _showTimeoutPicker(
    BuildContext context,
    WidgetRef ref,
    IdleModeSettings idleMode,
  ) async {
    const options = [1, 2, 5, 10, 15, 30];
    final choice = await showCupertinoModalPopup<int>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: const Text('Idle after'),
        actions: [
          for (final minutes in options)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, minutes),
              child: Text('$minutes min'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (choice != null) {
      await ref.read(idleModeProvider.notifier).setTimeoutMinutes(choice);
    }
  }

  Future<void> _showSetPinDialog(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final pin = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Set PIN'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: controller,
            keyboardType: TextInputType.number,
            obscureText: true,
            autofocus: true,
            placeholder: '4+ digits',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (pin == null || pin.length < 4) return;
    await ref.read(pinLockProvider.notifier).setPin(pin);
  }
}

class _AdminRow extends StatelessWidget {
  const _AdminRow({
    required this.icon,
    required this.title,
    required this.builder,
  });

  final IconData icon;
  final String title;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: const CupertinoListTileChevron(),
      onTap: () =>
          Navigator.of(context).push(CupertinoPageRoute(builder: builder)),
    );
  }
}
