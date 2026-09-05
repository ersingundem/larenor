import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/action_status_indicator.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/camera_snapshot.dart';
import '../../../shared/widgets/integration_health_status.dart';
import '../../auth/providers/auth_providers.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../health/data/integration_health.dart';
import '../../navigation/presentation/app_shell_actions.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../domain/door_station.dart';
import '../providers/intercom_providers.dart';

class IntercomScreen extends ConsumerWidget {
  const IntercomScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final stations = ref.watch(doorStationsProvider);
    final config = ref.watch(connectionConfigProvider);
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.intercomTitle),
        trailing: const AppShellActions(),
      ),
      child: SafeArea(
        child: ListView(
          key: const PageStorageKey('intercom'),
          padding: const EdgeInsets.all(20),
          children: [
            IntegrationHealthStatus(
              id: IntegrationId.ha,
              configured: config.value != null,
            ),
            const SizedBox(height: 20),
            stations.when(
              skipLoadingOnReload: false,
              loading: () => const Center(child: CupertinoActivityIndicator()),
              error: (_, _) => CupertinoButton(
                onPressed: () => ref.invalidate(doorStationsProvider),
                child: Text(l10n.commonRetry),
              ),
              data: (values) => values.isEmpty
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.intercomEmpty, style: AppText.title3),
                        const SizedBox(height: 8),
                        Text(l10n.intercomSetupDescription),
                        CupertinoButton(
                          onPressed: () => context.push('/settings'),
                          child: Text(l10n.navigationConfigure),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        for (final station in values)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: _DoorStationCard(
                              key: ValueKey(station.id),
                              station: station,
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DoorStationCard extends ConsumerStatefulWidget {
  const _DoorStationCard({super.key, required this.station});
  final DoorStation station;
  @override
  ConsumerState<_DoorStationCard> createState() => _DoorStationCardState();
}

class _DoorStationCardState extends MediaSessionState<_DoorStationCard> {
  bool _busy = false;
  bool _confirming = false;
  String? _error;
  Route<Map<String, String>>? _confirmation;
  TextEditingController? _code;

  @override
  void clearPendingInteraction() {
    _code?.clear();
    _error = null;
    final route = _confirmation;
    _confirmation = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  @override
  void didUpdateWidget(covariant _DoorStationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.station, widget.station)) {
      sessionGeneration++;
      clearPendingInteraction();
    }
  }

  Future<void> _release() async {
    if (_busy ||
        !sessionCurrent(sessionGeneration) ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _confirming = true;
      _error = null;
    });
    final interaction = sessionGeneration;
    final station = widget.station;
    try {
      final intent = ref.read(doorReleaseIntentProvider)(station);
      final entity = ref.read(entitiesProvider).value?[station.unlockEntityId];
      final needsCode =
          entity?.domain == 'lock' &&
          entity?.attributes['code_format'] is String &&
          (entity!.attributes['code_format'] as String).isNotEmpty;
      final code = TextEditingController();
      _code = code;
      Map<String, String>? approved;
      try {
        final route = CupertinoDialogRoute<Map<String, String>>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: Text(l10n.intercomConfirmTitle(station.name)),
            content: Column(
              children: [
                Text(l10n.intercomConfirmMessage),
                if (needsCode)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: CupertinoTextField(
                      controller: code,
                      obscureText: true,
                      maxLength: 128,
                      autocorrect: false,
                      enableSuggestions: false,
                      placeholder: l10n.intercomLockCode,
                    ),
                  ),
              ],
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () {
                  if (dialogContext.mounted &&
                      ModalRoute.of(dialogContext)?.isCurrent == true) {
                    Navigator.pop(dialogContext);
                  }
                },
                child: Text(l10n.commonCancel),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () {
                  if (sessionCurrent(interaction) &&
                      dialogContext.mounted &&
                      ModalRoute.of(dialogContext)?.isCurrent == true) {
                    Navigator.pop(dialogContext, {'code': code.text});
                  }
                },
                child: Text(l10n.intercomOpenDoor),
              ),
            ],
          ),
        );
        _confirmation = route;
        approved = await Navigator.of(context).push(route);
        if (identical(_confirmation, route)) _confirmation = null;
      } finally {
        if (identical(_code, code)) _code = null;
        code.dispose();
        if (mounted) setState(() => _confirming = false);
      }
      if (approved == null || !mounted) return;
      if (!sessionCurrent(interaction)) {
        setState(() => _error = l10n.intercomRecheck);
        return;
      }
      await ref.read(doorReleaseActionProvider)(
        intent,
        code: needsCode ? approved['code'] : null,
      );
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is DoorReleaseException
              ? l10n.intercomRecheck
              : actionErrorLabel(l10n, error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    watchMediaAccount(IntegrationId.ha, connectionConfigProvider);
    final l10n = AppLocalizations.of(context);
    final station = widget.station;
    final config = ref.watch(connectionConfigProvider);
    final states = ref.watch(entitiesProvider);
    final sameServer =
        !config.isReloading && config.value?.baseUrl == station.serverUrl;
    final entities = sameServer && !states.isReloading ? states.value : null;
    final block = ref.watch(doorReleaseBlockProvider(station));
    final blockedLabel = switch (block) {
      DoorReleaseBlock.notCommissioned => l10n.intercomReleaseDisabled,
      DoorReleaseBlock.differentServer => l10n.intercomDifferentServer,
      DoorReleaseBlock.noActiveCall => l10n.intercomWaitForCall,
      DoorReleaseBlock.staleState => l10n.intercomStale,
      null => null,
      _ => l10n.intercomRecheck,
    };
    return Container(
      constraints: const BoxConstraints(maxWidth: 900),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(station.name, style: AppText.title2),
          const SizedBox(height: 14),
          if (sameServer && station.cameraEntityId != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: CameraSnapshot(entityId: station.cameraEntityId!),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text(l10n.intercomNoVideo),
            ),
          const SizedBox(height: 16),
          if (station.chimeEntityId != null)
            Text(switch (entities?[station.chimeEntityId]?.state) {
              'on' => l10n.intercomRinging,
              'off' => l10n.intercomChimeQuiet,
              _ => l10n.intercomChimeUnknown,
            }),
          if (station.doorContactEntityId != null)
            Text(switch (entities?[station.doorContactEntityId]?.state) {
              'on' => l10n.intercomContactOpen,
              'off' => l10n.intercomContactClosed,
              _ => l10n.intercomContactUnknown,
            }),
          const SizedBox(height: 12),
          CupertinoButton.filled(
            onPressed: _busy || block != null ? null : _release,
            child: _busy && !_confirming
                ? const CupertinoActivityIndicator()
                : Text(l10n.intercomOpenDoor),
          ),
          if (blockedLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(blockedLabel),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(
                  color: CupertinoColors.systemRed.resolveFrom(context),
                ),
              ),
            ),
          if (station.unlockEntityId != null)
            ActionStatusIndicator(entityId: station.unlockEntityId!),
        ],
      ),
    );
  }
}
