import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../providers/keenetic_providers.dart';
import 'keenetic_connect_screen.dart';

class KeeneticDevicesScreen extends ConsumerWidget {
  const KeeneticDevicesScreen({super.key});

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
        return const _DevicesList();
      },
    );
  }
}

class _DevicesList extends ConsumerWidget {
  const _DevicesList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devicesAsync = ref.watch(keeneticDevicesProvider);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(AppLocalizations.of(context).keeneticConnectedDevices),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => ref.invalidate(keeneticDevicesProvider),
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: devicesAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(
            child: Text(
              AppLocalizations.of(context).adminLoadError(error.toString()),
            ),
          ),
          data: (devices) {
            if (devices.isEmpty) {
              return Center(
                child: Text(AppLocalizations.of(context).devicesScreenEmpty),
              );
            }
            return ListView(
              children: [
                const SizedBox(height: 16),
                CupertinoListSection.insetGrouped(
                  children: [
                    for (final device in devices)
                      CupertinoListTile(
                        leading: Icon(
                          device.active
                              ? CupertinoIcons.wifi
                              : CupertinoIcons.wifi_slash,
                          color: device.active
                              ? CupertinoColors.systemGreen.resolveFrom(context)
                              : CupertinoColors.systemGrey,
                        ),
                        title: Text(device.name),
                        subtitle: Text(device.ip ?? device.mac),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
