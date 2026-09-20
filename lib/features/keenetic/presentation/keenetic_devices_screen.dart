import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/direct_home_access.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
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

    return ServiceRootScaffold(
      title: l10n.keeneticConnectedDevices,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Semantics(
              key: const ValueKey('keenetic-devices-controls-header'),
              header: true,
              child: Text(l10n.keeneticConnectedDevices),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: CupertinoSearchTextField(
                    key: const ValueKey('keenetic-devices-search'),
                    placeholder: l10n.commonSearch,
                    onChanged: (value) {
                      if (keeneticCurrent(generation)) {
                        setState(() => _query = value);
                      }
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
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
              ),
              SettingsActionTile(
                buttonKey: const ValueKey('keenetic-devices-refresh'),
                title: Text(l10n.commonRefresh),
                onTap: () => _refresh(generation),
              ),
            ],
          ),
        ),
        devicesAsync.when(
          loading: () =>
              const SliverFilledMessage(child: CupertinoActivityIndicator()),
          error: (error, _) => SliverFilledMessage(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.healthReadError, textAlign: TextAlign.center),
            ),
          ),
          data: (devices) {
            if (devices.isEmpty) {
              return SliverFilledMessage(child: Text(l10n.devicesScreenEmpty));
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
            if (visibleDevices.isEmpty) {
              return SliverFilledMessage(child: Text(l10n.commonNoData));
            }
            return SliverSafeArea(
              top: false,
              sliver: SliverToBoxAdapter(
                child: SettingsSection(
                  header: Text(
                    l10n.keeneticTileDevicesOnline(
                      devices.where((device) => device.active).length,
                    ),
                  ),
                  children: [
                    for (final device in visibleDevices)
                      SettingsActionTile(
                        buttonKey: ValueKey('keenetic-device-${device.mac}'),
                        leading: Icon(
                          device.active
                              ? CupertinoIcons.wifi
                              : CupertinoIcons.wifi_slash,
                          color: device.active
                              ? CupertinoColors.systemGreen.resolveFrom(context)
                              : CupertinoColors.systemGrey,
                        ),
                        title: Text(device.name),
                        additionalInfo: Text(
                          '${device.ip ?? device.mac} · ${device.active ? l10n.keeneticOnline : l10n.keeneticOffline}',
                        ),
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
              ),
            );
          },
        ),
      ],
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
