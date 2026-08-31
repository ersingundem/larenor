import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/presentation/areas_screen.dart';
import '../../admin/presentation/automations_screen.dart';
import '../../admin/presentation/devices_screen.dart';
import '../../admin/presentation/entities_screen.dart';
import '../../admin/presentation/integrations_screen.dart';
import '../../auth/providers/auth_providers.dart';
import '../providers/settings_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(connectionConfigProvider).value;
    final keepScreenOn = ref.watch(keepScreenOnProvider);

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
