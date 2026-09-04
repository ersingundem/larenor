import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/models/keenetic_device.dart';
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

class _DevicesList extends ConsumerStatefulWidget {
  const _DevicesList();

  @override
  ConsumerState<_DevicesList> createState() => _DevicesListState();
}

class _DevicesListState extends ConsumerState<_DevicesList> {
  String _query = '';
  bool _onlineOnly = false;

  void _refresh() {
    if (ref.read(keeneticClientProvider).hasError) {
      ref.invalidate(keeneticClientProvider);
    }
    ref.invalidate(keeneticDevicesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final devicesAsync = ref.watch(keeneticDevicesProvider);
    final l10n = AppLocalizations.of(context);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(AppLocalizations.of(context).keeneticConnectedDevices),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _refresh,
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: devicesAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.adminLoadError(error.toString()),
                    textAlign: TextAlign.center,
                  ),
                  CupertinoButton(
                    onPressed: _refresh,
                    child: Text(l10n.commonRetry),
                  ),
                ],
              ),
            ),
          ),
          data: (devices) {
            if (devices.isEmpty) {
              return Center(
                child: Text(AppLocalizations.of(context).devicesScreenEmpty),
              );
            }
            final query = _query.trim().toLowerCase();
            final visibleDevices = devices.where((device) {
              if (_onlineOnly && !device.active) return false;
              return [
                device.name,
                device.mac,
                device.ip ?? '',
                device.interfaceId ?? '',
              ].any((field) => field.toLowerCase().contains(query));
            }).toList();
            return ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: CupertinoSearchTextField(
                    placeholder: l10n.commonSearch,
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: CupertinoSlidingSegmentedControl<bool>(
                    groupValue: _onlineOnly,
                    children: {
                      false: Text(l10n.keeneticAllDevices),
                      true: Text(l10n.keeneticOnline),
                    },
                    onValueChanged: (value) {
                      if (value != null) setState(() => _onlineOnly = value);
                    },
                  ),
                ),
                if (visibleDevices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(l10n.commonNoData, textAlign: TextAlign.center),
                  )
                else
                  CupertinoListSection.insetGrouped(
                    header: Text(
                      l10n.keeneticTileDevicesOnline(
                        devices.where((device) => device.active).length,
                      ),
                    ),
                    children: [
                      for (final device in visibleDevices)
                        CupertinoListTile(
                          leading: Icon(
                            device.active
                                ? CupertinoIcons.wifi
                                : CupertinoIcons.wifi_slash,
                            color: device.active
                                ? CupertinoColors.systemGreen.resolveFrom(
                                    context,
                                  )
                                : CupertinoColors.systemGrey,
                          ),
                          title: Text(device.name),
                          subtitle: Text(
                            '${device.ip ?? device.mac} · ${device.active ? l10n.keeneticOnline : l10n.keeneticOffline}',
                          ),
                          trailing: const CupertinoListTileChevron(),
                          onTap: () => Navigator.of(context).push(
                            CupertinoPageRoute(
                              builder: (_) => _DeviceDetails(device: device),
                            ),
                          ),
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

class _DeviceDetails extends StatelessWidget {
  const _DeviceDetails({required this.device});

  final KeeneticDevice device;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        context,
      ),
      navigationBar: CupertinoNavigationBar(
        middle: Text(device.name, overflow: TextOverflow.ellipsis),
      ),
      child: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 32, bottom: 12),
              child: Icon(
                device.active ? CupertinoIcons.wifi : CupertinoIcons.wifi_slash,
                size: 48,
                color: device.active
                    ? CupertinoColors.systemGreen
                    : CupertinoColors.systemGrey,
              ),
            ),
            Text(
              device.active ? l10n.keeneticOnline : l10n.keeneticOffline,
              textAlign: TextAlign.center,
            ),
            CupertinoListSection.insetGrouped(
              children: [
                _detail(
                  l10n.keeneticIpAddress,
                  device.ip ?? l10n.commonUnknown,
                ),
                _detail(l10n.keeneticMacAddress, device.mac),
                if (device.interfaceId != null)
                  _detail(l10n.keeneticInterface, device.interfaceId!),
                _detail(
                  l10n.keeneticRegistered,
                  device.registered ? l10n.commonYes : l10n.commonNo,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _detail(String title, String value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      children: [
        Expanded(child: Text(title)),
        const SizedBox(width: 16),
        Flexible(child: SelectableText(value, textAlign: TextAlign.end)),
      ],
    ),
  );
}
