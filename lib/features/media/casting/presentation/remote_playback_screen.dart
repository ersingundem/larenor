import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
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

  bool _current(int generation, RemotePlaybackController controller) =>
      sessionCurrent(generation) &&
      TickerMode.valuesOf(context).enabled &&
      identical(ref.read(remotePlaybackControllerProvider), controller);

  Future<void> _select(RemotePlaybackTarget target) async {
    if (!foreground ||
        sessionExpired ||
        _preparing != null ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final controller = ref.read(remotePlaybackControllerProvider);
    if (controller == null) return;
    final generation = sessionGeneration;
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
    final active =
        foreground && !sessionExpired && TickerMode.valuesOf(context).enabled;
    final reading = active ? ref.watch(remotePlaybackProvider) : null;
    final snapshot = reading == null || reading.isLoading || reading.hasError
        ? null
        : reading.value;
    final busy = _preparing != null || snapshot?.isBusy == true;
    final receipt =
        snapshot?.receipt?.itemId ==
            widget.itemId.replaceAll('-', '').toLowerCase()
        ? snapshot?.receipt
        : null;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.mediaRemoteTitle),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(CupertinoIcons.tv, size: 36),
                        const SizedBox(height: 16),
                        Text(l10n.mediaRemoteHint, style: AppText.body),
                        const SizedBox(height: 16),
                        if (sessionExpired)
                          Text(l10n.mediaRemoteAccountChanged)
                        else if (reading?.hasError == true)
                          Text(l10n.healthReadError)
                        else if (reading?.isLoading == true ||
                            snapshot?.isLoading == true)
                          const CupertinoActivityIndicator()
                        else if (snapshot?.configured == false)
                          Text(l10n.commonNotConnected)
                        else if (snapshot != null &&
                            snapshot.targets.isEmpty &&
                            snapshot.failure == null)
                          Text(l10n.mediaRemoteEmpty),
                        if (_error != null)
                          Text(_error!)
                        else if (snapshot?.outcomeUnknown == true)
                          Text(l10n.mediaRemoteUnconfirmed)
                        else if (snapshot?.failure != null)
                          Text(
                            remotePlaybackFailureLabel(
                              l10n,
                              snapshot!.failure!,
                            ),
                          ),
                        if (snapshot?.readAt != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              l10n.healthLastSuccessfulRead(
                                DateFormat.yMd(l10n.localeName)
                                    .add_Hms()
                                    .format(snapshot!.readAt!.toLocal()),
                              ),
                              style: AppText.footnote,
                            ),
                          ),
                        CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed:
                              !active || busy || snapshot?.isLoading == true
                              ? null
                              : () {
                                  setState(() => _error = null);
                                  ref
                                      .read(remotePlaybackControllerProvider)
                                      ?.refresh();
                                },
                          child: Text(l10n.commonRefresh),
                        ),
                      ],
                    ),
                  ),
                ),
                if (receipt != null)
                  SliverToBoxAdapter(
                    child: _Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(receipt.target.name, style: AppText.headline),
                          const SizedBox(height: 8),
                          Text(switch (receipt.status) {
                            RemotePlaybackReceiptStatus.accepted =>
                              l10n.mediaRemoteAccepted,
                            RemotePlaybackReceiptStatus.observed =>
                              l10n.mediaRemoteObserved,
                            RemotePlaybackReceiptStatus.unconfirmed =>
                              l10n.mediaRemoteUnconfirmed,
                          }),
                        ],
                      ),
                    ),
                  ),
                if (snapshot != null)
                  SliverList.builder(
                    itemCount: snapshot.targets.length,
                    itemBuilder: (context, index) {
                      final target = snapshot.targets[index];
                      return _Card(
                        child: CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed:
                              busy ||
                                  snapshot.failure != null ||
                                  snapshot.isLoading ||
                                  !active
                              ? null
                              : () => _select(target),
                          child: Row(
                            children: [
                              const Icon(CupertinoIcons.tv),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      target.name,
                                      style: AppText.headline.copyWith(
                                        color: CupertinoColors.label
                                            .resolveFrom(context),
                                      ),
                                    ),
                                    Text(
                                      target.client,
                                      style: AppText.footnote.copyWith(
                                        color: CupertinoColors.secondaryLabel
                                            .resolveFrom(context),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (_preparing == target.sessionId)
                                const CupertinoActivityIndicator()
                              else
                                const Icon(
                                  CupertinoIcons.chevron_forward,
                                  size: 16,
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      borderRadius: BorderRadius.circular(20),
    ),
    child: child,
  );
}
