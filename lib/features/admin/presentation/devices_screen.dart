import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/admin_providers.dart';

class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devicesAsync = ref.watch(devicesProvider);
    final areasAsync = ref.watch(areasProvider);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Devices'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () {
            ref.invalidate(devicesProvider);
            ref.invalidate(areasProvider);
          },
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
            final areaNames = {
              for (final area in areasAsync.value ?? []) area.areaId: area.name,
            };

            return ListView(
              children: [
                const SizedBox(height: 16),
                CupertinoListSection.insetGrouped(
                  children: [
                    for (final device in devices)
                      CupertinoListTile(
                        title: Text(device.displayName),
                        subtitle: Text(
                          [
                            if (device.manufacturer != null)
                              device.manufacturer,
                            if (device.model != null) device.model,
                          ].whereType<String>().join(' · '),
                        ),
                        additionalInfo: device.areaId != null
                            ? Text(areaNames[device.areaId] ?? '')
                            : null,
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
