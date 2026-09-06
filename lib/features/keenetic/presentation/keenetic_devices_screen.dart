import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/direct_home_access.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../data/models/keenetic_device.dart';
import '../providers/keenetic_providers.dart';
import 'keenetic_session_guard.dart';

class KeeneticDevicesScreen extends ConsumerWidget {
  const KeeneticDevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    if (!ref.watch(directHomeAccessProvider).isCurrent) {
      return CupertinoPageScaffold(
        child: Center(child: Text(l10n.commonNotConnected)),
      );
    }
    final connectionAsync = ref.watch(keeneticConnectionProvider);

    return connectionAsync.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      skipError: false,
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) => CupertinoPageScaffold(
        child: Center(child: Text(l10n.healthReadError)),
      ),
      data: (config) {
        if (config == null) {
          return CupertinoPageScaffold(
            child: Center(child: Text(l10n.commonNotConnected)),
          );
        }
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

class _DevicesListState extends KeeneticSessionState<_DevicesList> {
  String _query = '';
  bool _onlineOnly = false;

  @override
  void clearPendingInteraction() {
    _query = '';
    _onlineOnly = false;
    super.clearPendingInteraction();
  }

  void _refresh(int generation) {
    if (!keeneticCurrent(generation)) return;
    if (ref.read(keeneticClientProvider).hasError) {
      ref.invalidate(keeneticClientProvider);
    }
    ref.invalidate(keeneticDevicesProvider);
  }

  @override
  Widget build(BuildContext context) {
    watchKeeneticSession();
    final generation = sessionGeneration;
    if (!keeneticAvailable) {
      return CupertinoPageScaffold(
        child: Center(
          child: Text(AppLocalizations.of(context).commonNotConnected),
        ),
      );
    }
    final devicesAsync = ref.watch(keeneticDevicesProvider);
    final l10n = AppLocalizations.of(context);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(AppLocalizations.of(context).keeneticConnectedDevices),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => _refresh(generation),
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
                  Text(l10n.healthReadError, textAlign: TextAlign.center),
                  CupertinoButton(
                    onPressed: () => _refresh(generation),
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
                    onChanged: (value) {
                      if (keeneticCurrent(generation)) {
                        setState(() => _query = value);
                      }
                    },
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
                      if (value != null && keeneticCurrent(generation)) {
                        setState(() => _onlineOnly = value);
                      }
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
                          onTap: () {
                            if (!keeneticCurrent(generation)) return;
                            final source = captureKeeneticSource();
                            if (source == null) return;
                            Navigator.of(context).push(
                              CupertinoPageRoute<void>(
                                builder: (_) => _DeviceDetails(
                                  device: device,
                                  sourceCurrent: source,
                                ),
                              ),
                            );
                          },
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

class _DeviceDetails extends ConsumerStatefulWidget {
  const _DeviceDetails({required this.device, required this.sourceCurrent});
  final bool Function() sourceCurrent;

  final KeeneticDevice device;

  @override
  ConsumerState<_DeviceDetails> createState() => _DeviceDetailsState();
}

class _DeviceDetailsState extends KeeneticSessionState<_DeviceDetails> {
  @override
  Widget build(BuildContext context) {
    watchKeeneticSession();
    final l10n = AppLocalizations.of(context);
    if (!keeneticAvailable || !widget.sourceCurrent()) {
      return CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(l10n.keeneticConnectedDevices),
        ),
        child: Center(child: Text(l10n.commonNotConnected)),
      );
    }
    final device = widget.device;
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
