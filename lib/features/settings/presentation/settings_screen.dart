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
import '../../keenetic/presentation/keenetic_home_screen.dart';
import '../../keenetic/providers/keenetic_providers.dart';
import '../../media/arr/presentation/lidarr_screen.dart';
import '../../media/arr/presentation/radarr_screen.dart';
import '../../media/arr/presentation/readarr_screen.dart';
import '../../media/arr/presentation/sonarr_screen.dart';
import '../../media/arr/providers/lidarr_providers.dart';
import '../../media/arr/providers/radarr_providers.dart';
import '../../media/arr/providers/readarr_providers.dart';
import '../../media/arr/providers/sonarr_providers.dart';
import '../../media/bazarr/presentation/bazarr_home_screen.dart';
import '../../media/bazarr/providers/bazarr_providers.dart';
import '../../media/jellyfin/presentation/jellyfin_home_screen.dart';
import '../../media/jellyfin/providers/jellyfin_providers.dart';
import '../../media/jellyseerr/presentation/jellyseerr_home_screen.dart';
import '../../media/jellyseerr/providers/jellyseerr_providers.dart';
import '../../media/prowlarr/presentation/prowlarr_indexers_screen.dart';
import '../../media/prowlarr/providers/prowlarr_providers.dart';
import '../../media/qbittorrent/presentation/qbittorrent_torrents_screen.dart';
import '../../media/qbittorrent/providers/qbittorrent_providers.dart';
import '../../proxmox/presentation/proxmox_nodes_screen.dart';
import '../../proxmox/providers/proxmox_providers.dart';
import '../data/app_service.dart';
import '../providers/enabled_services_providers.dart';
import '../providers/settings_providers.dart';
import 'manage_integrations_screen.dart';
import '../../../shared/widgets/brand_icon.dart';
import '../../../shared/widgets/icon_badge.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(connectionConfigProvider).value;
    final keepScreenOn = ref.watch(keepScreenOnProvider);
    final nightWindow = ref.watch(nightWindowProvider).value;
    final pin = ref.watch(pinLockProvider).value;
    final idleMode = ref.watch(idleModeProvider).value;
    final enabledServices =
        ref.watch(enabledServicesProvider).value ?? const {};

    bool active(AppService service, bool connected) =>
        enabledServices.contains(service) && connected;

    final integrationRows = <_AdminRow>[
      if (active(
        AppService.jellyfin,
        ref.watch(jellyfinConnectionProvider).value != null,
      ))
        _AdminRow(
          icon: CupertinoIcons.play_rectangle,
          color: CupertinoColors.systemPurple,
          service: AppService.jellyfin,
          title: 'Jellyfin',
          builder: (_) => const JellyfinHomeScreen(),
        ),
      if (active(
        AppService.jellyseerr,
        ref.watch(jellyseerrConnectionProvider).value != null,
      ))
        _AdminRow(
          icon: CupertinoIcons.search,
          color: CupertinoColors.systemBlue,
          service: AppService.jellyseerr,
          title: 'Jellyseerr',
          builder: (_) => const JellyseerrHomeScreen(),
        ),
      if (active(
        AppService.sonarr,
        ref.watch(sonarrConnectionProvider).value != null,
      ))
        _AdminRow(
          icon: CupertinoIcons.tv,
          color: CupertinoColors.systemIndigo,
          service: AppService.sonarr,
          title: 'Sonarr',
          builder: (_) => const SonarrScreen(),
        ),
      if (active(
        AppService.radarr,
        ref.watch(radarrConnectionProvider).value != null,
      ))
        _AdminRow(
          icon: CupertinoIcons.film,
          color: CupertinoColors.systemYellow,
          service: AppService.radarr,
          title: 'Radarr',
          builder: (_) => const RadarrScreen(),
        ),
      if (active(
        AppService.lidarr,
        ref.watch(lidarrConnectionProvider).value != null,
      ))
        _AdminRow(
          icon: CupertinoIcons.music_note,
          color: CupertinoColors.systemGreen,
          service: AppService.lidarr,
          title: 'Lidarr',
          builder: (_) => const LidarrScreen(),
        ),
      if (active(
        AppService.readarr,
        ref.watch(readarrConnectionProvider).value != null,
      ))
        _AdminRow(
          icon: CupertinoIcons.book,
          color: CupertinoColors.systemOrange,
          service: AppService.readarr,
          title: 'Readarr',
          builder: (_) => const ReadarrScreen(),
        ),
      if (active(
        AppService.bazarr,
        ref.watch(bazarrConnectionProvider).value != null,
      ))
        _AdminRow(
          icon: CupertinoIcons.captions_bubble,
          color: CupertinoColors.systemTeal,
          service: AppService.bazarr,
          title: 'Bazarr',
          builder: (_) => const BazarrHomeScreen(),
        ),
      if (active(
        AppService.prowlarr,
        ref.watch(prowlarrConnectionProvider).value != null,
      ))
        _AdminRow(
          icon: CupertinoIcons.dot_radiowaves_left_right,
          color: CupertinoColors.systemOrange,
          service: AppService.prowlarr,
          title: 'Prowlarr',
          builder: (_) => const ProwlarrIndexersScreen(),
        ),
      if (active(
        AppService.qbittorrent,
        ref.watch(qbittorrentConnectionProvider).value != null,
      ))
        _AdminRow(
          icon: CupertinoIcons.arrow_down_circle,
          color: CupertinoColors.systemBlue,
          service: AppService.qbittorrent,
          title: 'qBittorrent',
          builder: (_) => const QbittorrentTorrentsScreen(),
        ),
      if (active(
        AppService.proxmox,
        ref.watch(proxmoxConnectionProvider).value != null,
      ))
        _AdminRow(
          icon: CupertinoIcons.square_stack_3d_up,
          color: CupertinoColors.systemOrange,
          service: AppService.proxmox,
          title: 'Proxmox',
          builder: (_) => const ProxmoxNodesScreen(),
        ),
      if (active(
        AppService.keenetic,
        ref.watch(keeneticConnectionProvider).value != null,
      ))
        _AdminRow(
          icon: CupertinoIcons.wifi,
          color: CupertinoColors.systemGreen,
          title: 'Keenetic',
          builder: (_) => const KeeneticHomeScreen(),
        ),
    ];

    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: [
          const CupertinoSliverNavigationBar(largeTitle: Text('Settings')),
          SliverSafeArea(
            top: false,
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 16),
                CupertinoListSection.insetGrouped(
                  header: const Text('CONNECTION'),
                  children: [
                    CupertinoListTile(
                      leading: const IconBadge(
                        icon: CupertinoIcons.house_fill,
                        color: CupertinoColors.systemBlue,
                      ),
                      title: const Text('Home Assistant server'),
                      additionalInfo: Text(config?.baseUrl ?? 'Not connected'),
                    ),
                  ],
                ),
                CupertinoListSection.insetGrouped(
                  header: const Text('DISPLAY'),
                  children: [
                    CupertinoListTile(
                      leading: const IconBadge(
                        icon: CupertinoIcons.brightness,
                        color: CupertinoColors.systemYellow,
                      ),
                      title: const Text('Keep screen on'),
                      subtitle: const Text(
                        'Recommended for wall-mounted tablets',
                      ),
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
                        title: const Text('Idle/ambient mode'),
                        subtitle: const Text(
                          'Show a clock screen after inactivity',
                        ),
                        trailing: CupertinoSwitch(
                          value: idleMode.enabled,
                          onChanged: (value) => ref
                              .read(idleModeProvider.notifier)
                              .setEnabled(value),
                        ),
                      ),
                      if (idleMode.enabled)
                        CupertinoListTile(
                          title: const Text('After'),
                          additionalInfo: Text(
                            '${idleMode.timeoutMinutes} min',
                          ),
                          trailing: const CupertinoListTileChevron(),
                          onTap: () =>
                              _showTimeoutPicker(context, ref, idleMode),
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
                      leading: const IconBadge(
                        icon: CupertinoIcons.lock_fill,
                        color: CupertinoColors.systemRed,
                      ),
                      title: Text(pin == null ? 'Set PIN' : 'Change PIN'),
                      onTap: () => _showSetPinDialog(context, ref),
                    ),
                    if (pin != null)
                      CupertinoListTile(
                        leading: const IconBadge(
                          icon: CupertinoIcons.lock_open_fill,
                          color: CupertinoColors.systemGrey,
                        ),
                        title: const Text('Remove PIN'),
                        onTap: () =>
                            ref.read(pinLockProvider.notifier).clearPin(),
                      ),
                  ],
                ),
                CupertinoListSection.insetGrouped(
                  header: const Text('MANAGE HOME ASSISTANT'),
                  children: [
                    _AdminRow(
                      icon: CupertinoIcons.cube_box,
                      color: CupertinoColors.systemBlue,
                      title: 'Integrations',
                      builder: (_) => const IntegrationsScreen(),
                    ),
                    _AdminRow(
                      icon: CupertinoIcons.device_laptop,
                      color: CupertinoColors.systemGrey,
                      title: 'Devices',
                      builder: (_) => const DevicesScreen(),
                    ),
                    _AdminRow(
                      icon: CupertinoIcons.square_grid_2x2,
                      color: CupertinoColors.systemGreen,
                      title: 'Areas',
                      builder: (_) => const AreasScreen(),
                    ),
                    _AdminRow(
                      icon: CupertinoIcons.list_bullet,
                      color: CupertinoColors.systemIndigo,
                      title: 'Entities',
                      builder: (_) => const EntitiesScreen(),
                    ),
                    _AdminRow(
                      icon: CupertinoIcons.bolt,
                      color: CupertinoColors.systemOrange,
                      title: 'Automations',
                      builder: (_) => const AutomationsScreen(),
                    ),
                    _AdminRow(
                      icon: CupertinoIcons.videocam,
                      color: CupertinoColors.systemPurple,
                      title: 'Cameras',
                      builder: (_) => const CamerasScreen(),
                    ),
                  ],
                ),
                CupertinoListSection.insetGrouped(
                  header: const Text('INTEGRATIONS'),
                  footer: const Text(
                    'Only services you\'ve turned on and connected show up here — '
                    'manage them all from Manage Integrations.',
                  ),
                  children: [
                    ...integrationRows,
                    _AdminRow(
                      icon: CupertinoIcons.slider_horizontal_3,
                      color: CupertinoColors.systemGrey,
                      title: 'Manage Integrations',
                      builder: (_) => const ManageIntegrationsScreen(),
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
                            color: CupertinoColors.systemRed.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      ),
                      onTap: () async {
                        await ref
                            .read(connectionConfigProvider.notifier)
                            .signOut();
                        if (context.mounted) context.go('/');
                      },
                    ),
                  ],
                ),
              ]),
            ),
          ),
        ],
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
    required this.color,
    required this.title,
    required this.builder,
    this.service,
  });

  final IconData icon;
  final Color color;
  final String title;
  final WidgetBuilder builder;

  /// When set and a real vendored logo exists for it, that logo is shown
  /// via [BrandIcon] instead of the generic [icon]/[color] pair.
  final AppService? service;

  @override
  Widget build(BuildContext context) {
    final service = this.service;
    return CupertinoListTile(
      leading: service != null && hasBrandIcon(service)
          ? BrandIcon(service: service)
          : IconBadge(icon: icon, color: color),
      title: Text(title),
      trailing: const CupertinoListTileChevron(),
      onTap: () =>
          Navigator.of(context).push(CupertinoPageRoute(builder: builder)),
    );
  }
}
