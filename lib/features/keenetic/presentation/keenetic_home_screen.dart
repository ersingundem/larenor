import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../providers/keenetic_providers.dart';
import '../data/models/keenetic_router_status.dart';
import 'keenetic_connect_screen.dart';
import 'keenetic_devices_screen.dart';
import 'keenetic_port_forwarding_screen.dart';
import 'keenetic_wifi_screen.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/operational_service_scope.dart';
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
    final l10n = AppLocalizations.of(context);
    final status = ref.watch(keeneticRouterStatusProvider);
    final devices = ref.watch(keeneticDevicesProvider);
    final accessPoints = ref.watch(keeneticAccessPointsProvider);

    Future<void> refresh() async {
      if (ref.read(keeneticClientProvider).hasError) {
        ref.invalidate(keeneticClientProvider);
      }
      ref.invalidate(keeneticRouterStatusProvider);
      ref.invalidate(keeneticDevicesProvider);
      ref.invalidate(keeneticAccessPointsProvider);
      ref.invalidate(keeneticPortForwardingProvider);
      try {
        await Future.wait([
          ref.read(keeneticRouterStatusProvider.future),
          ref.read(keeneticDevicesProvider.future),
          ref.read(keeneticAccessPointsProvider.future),
        ]);
      } catch (_) {
        // Each card renders its own provider's failure and retry control.
      }
    }

    return ServiceRootScaffold(
      title: 'Keenetic',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            onPressed: refresh,
            child: Icon(
              CupertinoIcons.refresh,
              semanticLabel: l10n.commonRefresh,
            ),
          ),
          ServiceAccountAction(
            onSignOut: () =>
                ref.read(keeneticConnectionProvider.notifier).signOut(),
          ),
        ],
      ),
      slivers: [
        CupertinoSliverRefreshControl(onRefresh: refresh),
        SliverList(
          delegate: SliverChildListDelegate([
            const SizedBox(height: Gap.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: CupertinoColors.secondarySystemGroupedBackground
                      .resolveFrom(context),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: status.when(
                    loading: () => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CupertinoActivityIndicator()),
                    ),
                    error: (error, _) => Column(
                      children: [
                        const Icon(
                          CupertinoIcons.wifi_exclamationmark,
                          size: 32,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10n.adminLoadError(error.toString()),
                          textAlign: TextAlign.center,
                        ),
                        CupertinoButton(
                          onPressed: refresh,
                          child: Text(l10n.commonRetry),
                        ),
                      ],
                    ),
                    data: (router) => router == null
                        ? Text(l10n.commonNotConnected)
                        : _RouterSummary(router: router),
                  ),
                ),
              ),
            ),
            CupertinoListSection.insetGrouped(
              header: Text(l10n.keeneticRouterStatus),
              children: [
                CupertinoListTile(
                  leading: const Icon(CupertinoIcons.device_laptop),
                  title: Text(
                    AppLocalizations.of(context).keeneticConnectedDevices,
                  ),
                  subtitle: Text(
                    devices.when(
                      data: (value) => l10n.keeneticTileDevicesOnline(
                        value.where((device) => device.active).length,
                      ),
                      loading: () => l10n.commonLoading,
                      error: (_, _) => l10n.commonError,
                    ),
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
                  subtitle: Text(
                    accessPoints.when(
                      data: (value) => l10n.keeneticTileWifiUp(
                        value.where((ap) => ap.up).length,
                        value.length,
                      ),
                      loading: () => l10n.commonLoading,
                      error: (_, _) => l10n.commonError,
                    ),
                  ),
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

class _RouterSummary extends StatelessWidget {
  const _RouterSummary({required this.router});

  final KeeneticRouterStatus router;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final secondary = CupertinoColors.secondaryLabel.resolveFrom(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: CupertinoColors.systemBlue.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(
                CupertinoIcons.wifi,
                color: CupertinoColors.systemBlue,
                size: 28,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    router.model,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    router.hostname ?? l10n.keeneticOnline,
                    style: TextStyle(fontSize: 14, color: secondary),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (router.firmware != null) ...[
          const SizedBox(height: 16),
          Text(
            '${l10n.keeneticFirmware} ${router.firmware}',
            style: TextStyle(fontSize: 13, color: secondary),
          ),
        ],
        const SizedBox(height: 22),
        Wrap(
          spacing: 28,
          runSpacing: 20,
          children: [
            _Metric(
              label: l10n.keeneticCpuUsage,
              value: router.cpuPercent == null ? '—' : '${router.cpuPercent}%',
            ),
            _Metric(
              label: l10n.keeneticMemoryUsage,
              value: router.memoryPercent == null
                  ? '—'
                  : '${router.memoryPercent}%',
            ),
            _Metric(
              label: l10n.keeneticUptime,
              value: router.uptimeSeconds == null
                  ? '—'
                  : Duration(seconds: router.uptimeSeconds!)
                        .toString()
                        .split('.')
                        .first,
            ),
          ],
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 4),
      Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      ),
    ],
  );
}
