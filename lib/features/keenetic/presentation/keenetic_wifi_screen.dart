import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/direct_home_access.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/integration_health_status.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/service_route_status_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../health/data/integration_health.dart';
import '../data/keenetic_api_exception.dart';
import '../data/models/keenetic_access_point.dart';
import '../providers/keenetic_providers.dart';
import 'keenetic_session_guard.dart';

class KeeneticWifiScreen extends ConsumerWidget {
  const KeeneticWifiScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    if (!ref.watch(directHomeAccessProvider).isCurrent) {
      return ServiceRouteStatusScaffold(
        title: 'Keenetic',
        label: l10n.commonNotConnected,
        statusKey: const ValueKey('keenetic-wifi-unavailable'),
      );
    }
    final connectionAsync = ref.watch(keeneticConnectionProvider);

    return connectionAsync.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      skipError: false,
      loading: () => ServiceRouteStatusScaffold(
        title: l10n.keeneticWifi,
        label: l10n.commonLoading,
        statusKey: const ValueKey('keenetic-wifi-loading'),
        loading: true,
      ),
      error: (error, _) => ServiceRouteStatusScaffold(
        title: l10n.keeneticWifi,
        label: l10n.healthReadError,
        statusKey: const ValueKey('keenetic-wifi-error'),
      ),
      data: (config) {
        if (config == null) {
          return ServiceRouteStatusScaffold(
            title: l10n.keeneticWifi,
            label: l10n.navigationUnconfigured,
            statusKey: const ValueKey('keenetic-wifi-unconfigured'),
          );
        }
        return const _AccessPointsList();
      },
    );
  }
}

class _AccessPointsList extends ConsumerStatefulWidget {
  const _AccessPointsList();

  @override
  ConsumerState<_AccessPointsList> createState() => _AccessPointsListState();
}

class _AccessPointsListState extends KeeneticSessionState<_AccessPointsList> {
  final Set<String> _pending = {};

  Future<void> _setUp(
    KeeneticAccessPoint ap,
    bool value,
    int generation,
  ) async {
    if (!keeneticCurrent(generation) ||
        _pending.contains(ap.id) ||
        ownedModal != null) {
      return;
    }
    final reading = ref.read(keeneticClientProvider);
    final client = reading.isLoading || reading.hasError ? null : reading.value;
    if (client == null) return;
    bool current() {
      if (!keeneticCurrent(generation)) return false;
      final next = ref.read(keeneticClientProvider);
      return !next.isLoading && !next.hasError && identical(client, next.value);
    }

    final l10n = AppLocalizations.of(context);
    try {
      if (!value) {
        late final CupertinoDialogRoute<bool> route;
        route = CupertinoDialogRoute<bool>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: Text(l10n.keeneticDisableWifiTitle),
            content: Text(l10n.keeneticDisableWifiMessage(ap.ssid ?? ap.name)),
            actions: [
              CupertinoDialogAction(
                onPressed: () {
                  if (identical(ownedModal, route) &&
                      route.isCurrent &&
                      current()) {
                    Navigator.of(dialogContext).pop(false);
                  }
                },
                child: Text(l10n.commonCancel),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () {
                  if (identical(ownedModal, route) &&
                      route.isCurrent &&
                      current()) {
                    Navigator.of(dialogContext).pop(true);
                  }
                },
                child: Text(l10n.keeneticTurnOff),
              ),
            ],
          ),
        );
        ownedModal = route;
        final confirmed = await Navigator.of(context).push<bool>(route);
        if (identical(ownedModal, route)) ownedModal = null;
        if (confirmed != true || !current()) return;
      }
      if (!current()) return;
      setState(() => _pending.add(ap.id));
      await client.setInterfaceUp(ap.id, value);
      if (current()) ref.invalidate(keeneticAccessPointsProvider);
    } catch (error) {
      if (!mounted || !current()) return;
      setState(() => _pending.remove(ap.id));
      late final CupertinoDialogRoute<void> route;
      route = CupertinoDialogRoute<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(l10n.commonError),
          content: Text(
            error is KeeneticApiException
                ? error.message
                : l10n.keeneticErrorUnreachable,
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () {
                if (identical(ownedModal, route) &&
                    route.isCurrent &&
                    current()) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: Text(l10n.commonOk),
            ),
          ],
        ),
      );
      ownedModal = route;
      await Navigator.of(context).push<void>(route);
      if (identical(ownedModal, route)) ownedModal = null;
    } finally {
      if (mounted) setState(() => _pending.remove(ap.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    watchKeeneticSession();
    final generation = sessionGeneration;
    if (!keeneticAvailable) {
      final l10n = AppLocalizations.of(context);
      return ServiceRouteStatusScaffold(
        title: l10n.keeneticWifi,
        label: l10n.commonNotConnected,
        statusKey: const ValueKey('keenetic-wifi-unavailable'),
      );
    }
    final apsAsync = ref.watch(keeneticAccessPointsProvider);
    final clientAsync = ref.watch(keeneticClientProvider);

    final l10n = AppLocalizations.of(context);
    void refresh() {
      if (!keeneticCurrent(generation)) return;
      if (ref.read(keeneticClientProvider).hasError) {
        ref.invalidate(keeneticClientProvider);
      }
      ref.invalidate(keeneticAccessPointsProvider);
    }

    return apsAsync.when(
      loading: () => ServiceRouteStatusScaffold(
        title: l10n.keeneticWifi,
        label: l10n.commonLoading,
        statusKey: const ValueKey('keenetic-wifi-loading'),
        loading: true,
      ),
      error: (error, _) => ServiceRouteStatusScaffold(
        title: l10n.keeneticWifi,
        label: l10n.healthReadError,
        statusKey: const ValueKey('keenetic-wifi-error'),
        actionLabel: l10n.commonRetry,
        actionKey: const ValueKey('keenetic-wifi-refresh'),
        onAction: refresh,
      ),
      data: (aps) {
        if (aps.isEmpty) {
          return ServiceRouteStatusScaffold(
            title: l10n.keeneticWifi,
            label: l10n.keeneticNoAccessPoints,
            statusKey: const ValueKey('keenetic-wifi-empty'),
            actionLabel: l10n.commonRefresh,
            actionKey: const ValueKey('keenetic-wifi-refresh'),
            onAction: refresh,
          );
        }
        return ServiceRootScaffold(
          title: l10n.keeneticWifi,
          slivers: [
            SliverToBoxAdapter(
              child: SettingsSection(
                header: Semantics(
                  key: const ValueKey('keenetic-wifi-heading'),
                  container: true,
                  header: true,
                  child: Text(l10n.keeneticWifi),
                ),
                footer: Text(l10n.keeneticWifiChangesSaved),
                children: [
                  const CupertinoListTile(
                    title: IntegrationHealthStatus(
                      id: IntegrationId.keenetic,
                      configured: true,
                    ),
                  ),
                  SettingsActionTile(
                    buttonKey: const ValueKey('keenetic-wifi-refresh'),
                    leading: const Icon(CupertinoIcons.refresh),
                    title: Text(l10n.commonRefresh),
                    onTap: refresh,
                  ),
                  for (final ap in aps)
                    MergeSemantics(
                      key: ValueKey('keenetic-wifi-toggle-${ap.id}'),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: CupertinoListTile(
                          title: Text(ap.name),
                          leading: Icon(
                            ap.up
                                ? CupertinoIcons.wifi
                                : CupertinoIcons.wifi_slash,
                            color: ap.up
                                ? CupertinoColors.systemBlue
                                : CupertinoColors.systemGrey,
                          ),
                          subtitle: Text(
                            [
                              if (ap.ssid != null && ap.ssid != ap.name)
                                ap.ssid!,
                              _interfaceLabel(context, ap.id),
                            ].join(' · '),
                          ),
                          trailing: _pending.contains(ap.id)
                              ? const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 14),
                                  child: CupertinoActivityIndicator(),
                                )
                              : CupertinoSwitch(
                                  value: ap.up,
                                  onChanged:
                                      !keeneticCurrent(generation) ||
                                          clientAsync.isLoading ||
                                          clientAsync.hasError ||
                                          clientAsync.value == null ||
                                          parseKeeneticWifiInterfaceId(ap.id) ==
                                              null
                                      ? null
                                      : (value) =>
                                            _setUp(ap, value, generation),
                                ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  String _interfaceLabel(BuildContext context, String id) {
    final parsed = parseKeeneticWifiInterfaceId(id);
    if (parsed == null) return id;
    return AppLocalizations.of(context)
        .keeneticWifiRadioLabel(parsed.$1, parsed.$2);
  }
}
