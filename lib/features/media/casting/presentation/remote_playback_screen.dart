import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/connection_evidence_status.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../health/data/connection_evidence.dart';
import '../../../health/data/integration_health.dart';
import '../../../health/presentation/health_labels.dart';
import '../../hub/presentation/media_session_state.dart';
import '../data/remote_playback_controller.dart';
import '../domain/remote_playback_models.dart';
import '../providers/remote_playback_providers.dart';

String remotePlaybackFailureLabel(
  AppLocalizations l10n,
  RemotePlaybackFailure failure,
) => switch (failure) {
  RemotePlaybackFailure.authentication => healthFailureLabel(
    l10n,
    HealthFailure.authentication,
  ),
  RemotePlaybackFailure.permission => healthFailureLabel(
    l10n,
    HealthFailure.permission,
  ),
  RemotePlaybackFailure.transport => healthFailureLabel(
    l10n,
    HealthFailure.transport,
  ),
  RemotePlaybackFailure.timeout => healthFailureLabel(
    l10n,
    HealthFailure.timeout,
  ),
  RemotePlaybackFailure.invalidResponse => healthFailureLabel(
    l10n,
    HealthFailure.invalidResponse,
  ),
  RemotePlaybackFailure.unavailable => l10n.mediaRemoteUnavailable,
  RemotePlaybackFailure.unsupportedItem => l10n.mediaRemoteUnsupportedItem,
  RemotePlaybackFailure.invalidIntent ||
  RemotePlaybackFailure.expiredIntent => l10n.mediaRemoteExpired,
  RemotePlaybackFailure.busy => l10n.mediaRemoteBusy,
};

ConnectionEvidence _remotePlaybackEvidence({
  required bool configured,
  required bool loading,
  required bool readFailed,
  required RemotePlaybackSnapshot? snapshot,
}) {
  if (!configured || snapshot?.configured == false) {
    return const ConnectionEvidence.none();
  }
  final verifiedAt = snapshot?.readAt;
  final stage = verifiedAt == null
      ? ConnectionEvidenceStage.saved
      : ConnectionEvidenceStage.verified;
  if (loading || snapshot?.isLoading == true) {
    return verifiedAt == null
        ? const ConnectionEvidence.connecting()
        : ConnectionEvidence.retrying(stage: stage, lastVerifiedAt: verifiedAt);
  }
  if (readFailed) {
    return ConnectionEvidence.error(stage: stage, lastVerifiedAt: verifiedAt);
  }
  final failure = snapshot?.failure;
  if (failure != null) {
    return switch (failure) {
      RemotePlaybackFailure.authentication =>
        ConnectionEvidence.authenticationRequired(
          stage: stage,
          lastVerifiedAt: verifiedAt,
        ),
      RemotePlaybackFailure.permission => ConnectionEvidence.permissionDenied(
        stage: stage,
        lastVerifiedAt: verifiedAt,
      ),
      RemotePlaybackFailure.transport ||
      RemotePlaybackFailure.timeout => ConnectionEvidence.unavailable(
        stage: stage,
        lastVerifiedAt: verifiedAt,
      ),
      _ => ConnectionEvidence.error(stage: stage, lastVerifiedAt: verifiedAt),
    };
  }
  if (verifiedAt != null) return ConnectionEvidence.verified(verifiedAt);
  return const ConnectionEvidence.saved();
}

class RemotePlaybackScreen extends ConsumerStatefulWidget {
  const RemotePlaybackScreen({super.key, required this.itemId});
  final String itemId;
  @override
  ConsumerState<RemotePlaybackScreen> createState() =>
      _RemotePlaybackScreenState();
}

class _RemotePlaybackScreenState
    extends MediaSessionState<RemotePlaybackScreen> {
  String? _preparing;
  String? _error;
  Route<bool>? _confirmation;

  @override
  void didUpdateWidget(covariant RemotePlaybackScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemId != widget.itemId) {
      sessionGeneration++;
      clearPendingInteraction();
    }
  }

  @override
  void clearPendingInteraction() {
    _preparing = null;
    _error = null;
    final route = _confirmation;
    _confirmation = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  bool _surfaceCurrent(int generation) =>
      sessionCurrent(generation) &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent == true ||
          _confirmation?.isCurrent == true);

  bool _current(int generation, RemotePlaybackController controller) =>
      _surfaceCurrent(generation) &&
      identical(ref.read(remotePlaybackControllerProvider), controller);

  Future<void> _select(RemotePlaybackTarget target) async {
    final generation = sessionGeneration;
    if (!_surfaceCurrent(generation) || _preparing != null || !mounted) {
      return;
    }
    final controller = ref.read(remotePlaybackControllerProvider);
    if (controller == null) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _preparing = target.sessionId;
      _error = null;
    });
    try {
      final intent = await controller.createIntent(target, widget.itemId);
      if (!mounted || !_current(generation, controller)) return;
      final route = CupertinoDialogRoute<bool>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(l10n.mediaRemoteConfirm),
          content: Column(
            children: [
              const SizedBox(height: 12),
              Text('${l10n.mediaRemoteItem}: ${intent.itemTitle}'),
              Text('${l10n.mediaRemoteDevice}: ${intent.target.name}'),
              const SizedBox(height: 12),
              Text(l10n.mediaRemoteReplaceHint),
            ],
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () {
                if (dialogContext.mounted &&
                    ModalRoute.of(dialogContext)?.isCurrent == true) {
                  Navigator.pop(dialogContext, false);
                }
              },
              child: Text(l10n.commonCancel),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () {
                if (_current(generation, controller) &&
                    dialogContext.mounted &&
                    ModalRoute.of(dialogContext)?.isCurrent == true) {
                  Navigator.pop(dialogContext, true);
                }
              },
              child: Text(l10n.mediaActionPlay),
            ),
          ],
        ),
      );
      _confirmation = route;
      final confirmed = await Navigator.of(context).push(route);
      if (identical(_confirmation, route)) _confirmation = null;
      if (confirmed != true || !_current(generation, controller)) return;
      await controller.play(intent);
    } catch (error) {
      if (_current(generation, controller)) {
        setState(
          () => _error = error is RemotePlaybackException
              ? error.outcomeUnknown
                    ? l10n.mediaRemoteUnconfirmed
                    : remotePlaybackFailureLabel(l10n, error.failure)
              : l10n.healthReadError,
        );
      }
    } finally {
      if (mounted && sessionCurrent(generation)) {
        setState(() => _preparing = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    watchMediaAccounts(jellyfinOnly: true);
    final l10n = AppLocalizations.of(context);
    final generation = sessionGeneration;
    final active = _surfaceCurrent(generation);
    final configured = ref.watch(remotePlaybackControllerProvider) != null;
    final reading = active ? ref.watch(remotePlaybackProvider) : null;
    final snapshot = reading == null || reading.isLoading || reading.hasError
        ? null
        : reading.value;
    final busy = _preparing != null || snapshot?.isBusy == true;
    final evidence = _remotePlaybackEvidence(
      configured: configured,
      loading: reading?.isLoading == true,
      readFailed: reading?.hasError == true,
      snapshot: snapshot,
    );
    final receipt =
        snapshot?.receipt?.itemId ==
            widget.itemId.replaceAll('-', '').toLowerCase()
        ? snapshot?.receipt
        : null;
    return ServiceRootScaffold(
      title: l10n.mediaRemoteTitle,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Semantics(
              key: const ValueKey('remote-playback-devices-heading'),
              container: true,
              header: true,
              child: Text(l10n.mediaRemoteDevice),
            ),
            footer: Text(l10n.mediaRemoteHint),
            children: [
              if (!sessionExpired)
                CupertinoListTile(
                  title: ConnectionEvidenceStatus(evidence: evidence),
                ),
              if (sessionExpired)
                _RemotePlaybackStatus(
                  key: const ValueKey('remote-playback-account-status'),
                  label: l10n.mediaRemoteAccountChanged,
                )
              else if (reading?.hasError == true)
                _RemotePlaybackStatus(
                  key: const ValueKey('remote-playback-read-status'),
                  label: l10n.healthReadError,
                )
              else if (reading?.isLoading == true ||
                  snapshot?.isLoading == true)
                _RemotePlaybackStatus(
                  key: const ValueKey('remote-playback-loading-status'),
                  label: l10n.commonLoading,
                  loading: true,
                )
              else if (snapshot?.configured == false)
                _RemotePlaybackStatus(
                  key: const ValueKey('remote-playback-connection-status'),
                  label: l10n.commonNotConnected,
                )
              else if (snapshot != null &&
                  snapshot.targets.isEmpty &&
                  snapshot.failure == null)
                _RemotePlaybackStatus(
                  key: const ValueKey('remote-playback-empty-status'),
                  label: l10n.mediaRemoteEmpty,
                ),
              if (_error != null)
                _RemotePlaybackStatus(
                  key: const ValueKey('remote-playback-action-status'),
                  label: _error!,
                )
              else if (snapshot?.outcomeUnknown == true)
                _RemotePlaybackStatus(
                  key: const ValueKey('remote-playback-action-status'),
                  label: l10n.mediaRemoteUnconfirmed,
                ),
              if (snapshot?.readAt != null)
                CupertinoListTile(
                  title: Text(
                    l10n.healthLastSuccessfulRead(
                      DateFormat.yMd(l10n.localeName)
                          .add_Hms()
                          .format(snapshot!.readAt!.toLocal()),
                    ),
                  ),
                ),
              SettingsActionTile(
                buttonKey: const ValueKey('remote-playback-refresh'),
                leading: const Icon(CupertinoIcons.refresh),
                title: Text(l10n.commonRefresh),
                onTap: !active || busy || snapshot?.isLoading == true
                    ? null
                    : () {
                        final controller = ref.read(
                          remotePlaybackControllerProvider,
                        );
                        if (controller == null ||
                            !_current(generation, controller)) {
                          return;
                        }
                        setState(() => _error = null);
                        controller.refresh();
                      },
              ),
            ],
          ),
        ),
        if (receipt != null)
          SliverToBoxAdapter(
            child: SettingsSection(
              children: [
                CupertinoListTile(
                  title: Text(receipt.target.name),
                  subtitle: Text(switch (receipt.status) {
                    RemotePlaybackReceiptStatus.accepted =>
                      l10n.mediaRemoteAccepted,
                    RemotePlaybackReceiptStatus.observed =>
                      l10n.mediaRemoteObserved,
                    RemotePlaybackReceiptStatus.unconfirmed =>
                      l10n.mediaRemoteUnconfirmed,
                  }),
                ),
              ],
            ),
          ),
        if (snapshot != null)
          SliverList.builder(
            itemCount: snapshot.targets.length,
            itemBuilder: (context, index) {
              final target = snapshot.targets[index];
              return SettingsSection(
                children: [
                  SettingsActionTile(
                    buttonKey: ValueKey(
                      'remote-playback-target-${target.sessionId}',
                    ),
                    leading: _preparing == target.sessionId
                        ? const CupertinoActivityIndicator()
                        : const Icon(CupertinoIcons.tv),
                    title: Text(target.name),
                    additionalInfo: Text(target.client),
                    onTap:
                        busy ||
                            snapshot.failure != null ||
                            snapshot.isLoading ||
                            !active
                        ? null
                        : guardedMediaAction(() => _select(target)),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }
}

class _RemotePlaybackStatus extends StatelessWidget {
  const _RemotePlaybackStatus({
    super.key,
    required this.label,
    this.loading = false,
  });

  final String label;
  final bool loading;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: label,
    excludeSemantics: true,
    child: CupertinoListTile(
      title: Text(label),
      trailing: loading ? const CupertinoActivityIndicator() : null,
    ),
  );
}
