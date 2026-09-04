import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../providers/admin_providers.dart';

class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final devicesAsync = ref.watch(devicesProvider);
    final areasAsync = ref.watch(areasProvider);

    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.settingsDevices),
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () {
                ref.invalidate(devicesProvider);
                ref.invalidate(areasProvider);
              },
              child: const Icon(CupertinoIcons.refresh),
            ),
          ),
          devicesAsync.when(
            loading: () => const SliverFillRemaining(
              child: Center(child: CupertinoActivityIndicator()),
            ),
            error: (error, _) => SliverFillRemaining(
              child: Center(child: Text(l10n.adminLoadError(error.toString()))),
            ),
            data: (devices) {
              if (devices.isEmpty) {
                return SliverFillRemaining(
                  child: Center(child: Text(l10n.devicesScreenEmpty)),
                );
              }
              final areaNames = {
                for (final area in areasAsync.value ?? [])
                  area.areaId: area.name,
              };

              return SliverSafeArea(
                top: false,
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    const SizedBox(height: 16),
                    CupertinoListSection.insetGrouped(
                      children: [
                        for (final device in devices)
                          CupertinoListTile(
                            leading: IconBadge(
                              icon: CupertinoIcons.device_laptop,
                              color: CupertinoColors.systemGrey.resolveFrom(
                                context,
                              ),
                            ),
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
                  ]),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
