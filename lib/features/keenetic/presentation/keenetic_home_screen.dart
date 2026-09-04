import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../providers/keenetic_providers.dart';
import 'keenetic_connect_screen.dart';
import 'keenetic_devices_screen.dart';
import 'keenetic_port_forwarding_screen.dart';
import 'keenetic_wifi_screen.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/theme/spacing.dart';

class KeeneticHomeScreen extends ConsumerWidget {
  const KeeneticHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(keeneticConnectionProvider);

    return connectionAsync.when(
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) =>
          CupertinoPageScaffold(child: Center(child: Text(error.toString()))),
      data: (config) {
        if (config == null) return const KeeneticConnectScreen();
        return const _KeeneticMenu();
      },
    );
  }
}

class _KeeneticMenu extends ConsumerWidget {
  const _KeeneticMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ServiceRootScaffold(
      title: 'Keenetic',
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: () =>
            ref.read(keeneticConnectionProvider.notifier).signOut(),
        child: const Icon(CupertinoIcons.square_arrow_right),
      ),
      slivers: [
        SliverList(
          delegate: SliverChildListDelegate([
            const SizedBox(height: Gap.sm),
            CupertinoListSection.insetGrouped(
              children: [
                CupertinoListTile(
                  leading: const Icon(CupertinoIcons.device_laptop),
                  title: Text(
                    AppLocalizations.of(context).keeneticConnectedDevices,
                  ),
                  trailing: const CupertinoListTileChevron(),
                  onTap: () => Navigator.of(context).push(
                    CupertinoPageRoute(
                      builder: (_) => const KeeneticDevicesScreen(),
                    ),
                  ),
                ),
                CupertinoListTile(
                  leading: const Icon(CupertinoIcons.wifi),
                  title: Text(AppLocalizations.of(context).keeneticWifi),
                  trailing: const CupertinoListTileChevron(),
                  onTap: () => Navigator.of(context).push(
                    CupertinoPageRoute(
                      builder: (_) => const KeeneticWifiScreen(),
                    ),
                  ),
                ),
                CupertinoListTile(
                  leading: const Icon(CupertinoIcons.arrow_right_arrow_left),
                  title: Text(
                    AppLocalizations.of(context).keeneticPortForwarding,
                  ),
                  trailing: const CupertinoListTileChevron(),
                  onTap: () => Navigator.of(context).push(
                    CupertinoPageRoute(
                      builder: (_) => const KeeneticPortForwardingScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ]),
        ),
      ],
    );
  }
}
