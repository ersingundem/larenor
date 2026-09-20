import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/settings_section.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../media/hub/presentation/media_session_state.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../data/admin_client.dart';
import '../data/models/ha_device.dart';
import '../providers/admin_providers.dart';
import 'registry_editor_screen.dart';

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends MediaSessionState<DevicesScreen> {
  String _query = '';

  bool _current(int generation, HaAdminClient client) =>
      sessionCurrent(generation) &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true &&
      identical(ref.read(haAdminClientProvider), client);

  void _open(HaDevice device, int generation, HaAdminClient client) {
    if (!_current(generation, client)) return;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => RegistryEditorScreen.device(device),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final devicesAsync = ref.watch(devicesProvider);
    final areasAsync = ref.watch(areasProvider);
    final client = ref.watch(haAdminClientProvider);
    final generation = sessionGeneration;
    final active = client != null && _current(generation, client);

    return ServiceRootScaffold(
      title: l10n.settingsDevices,
      leading: Semantics(
        key: const ValueKey('devices-refresh'),
        container: true,
        button: true,
        enabled: active,
        label: l10n.commonRefresh,
        child: ExcludeSemantics(
          child: CupertinoButton(
            minimumSize: const Size(48, 48),
            padding: EdgeInsets.zero,
            onPressed: active
                ? () {
                    if (!_current(generation, client)) return;
                    ref.invalidate(devicesProvider);
                    ref.invalidate(areasProvider);
                  }
                : null,
            child: const Icon(CupertinoIcons.refresh),
          ),
        ),
      ),
      slivers: [
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
              for (final area in areasAsync.value ?? []) area.areaId: area.name,
            };

            return SliverSafeArea(
              top: false,
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: ConstrainedBox(
                      key: const ValueKey('devices-search'),
                      constraints: const BoxConstraints(minHeight: 48),
                      child: CupertinoSearchTextField(
                        onChanged: active
                            ? (value) {
                                if (_current(generation, client)) {
                                  setState(() => _query = value.toLowerCase());
                                }
                              }
                            : null,
                      ),
                    ),
                  ),
                  SettingsSection(
                    header: Semantics(
                      key: const ValueKey('devices-list-header'),
                      header: true,
                      child: Text(l10n.settingsDevices),
                    ),
                    children: [
                      for (final device in devices.where(
                        (device) =>
                            '${device.displayName} ${device.manufacturer ?? ''} ${device.model ?? ''}'
                                .toLowerCase()
                                .contains(_query),
                      ))
                        SettingsActionTile(
                          buttonKey: ValueKey('admin-device-${device.id}'),
                          leading: IconBadge(
                            icon: CupertinoIcons.device_laptop,
                            color: CupertinoColors.systemGrey.resolveFrom(
                              context,
                            ),
                          ),
                          title: Text(device.displayName),
                          onTap: active
                              ? () => _open(device, generation, client)
                              : null,
                          additionalInfo: Text(
                            [
                              if (device.manufacturer != null)
                                device.manufacturer,
                              if (device.model != null) device.model,
                              if (device.areaId != null)
                                areaNames[device.areaId] ?? '',
                            ].whereType<String>().join(' · '),
                          ),
                        ),
                    ],
                  ),
                ]),
              ),
            );
          },
        ),
      ],
    );
  }
}
