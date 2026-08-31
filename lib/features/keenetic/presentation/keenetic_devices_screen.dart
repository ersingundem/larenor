import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
          CupertinoPageScaffold(child: Center(child: Text('$error'))),
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
        middle: const Text('Connected Devices'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => ref.invalidate(keeneticDevicesProvider),
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: devicesAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('Failed to load: $error')),
          data: (devices) {
            if (devices.isEmpty) {
              return const Center(child: Text('No devices found'));
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
