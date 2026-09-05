import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../auth/providers/auth_providers.dart';
import '../../../health/data/integration_health.dart';
import '../../../health/presentation/health_labels.dart';
import '../../hub/presentation/media_session_state.dart';
import '../data/music_playback_controller.dart';
import '../domain/music_models.dart';
import '../domain/music_playback_models.dart';
import '../providers/music_playback_providers.dart';
import '../providers/music_providers.dart';

String musicPlaybackFailureLabel(
  AppLocalizations l10n,
  MusicPlaybackFailure value,
) => switch (value) {
  MusicPlaybackFailure.authentication => healthFailureLabel(
    l10n,
    HealthFailure.authentication,
  ),
  MusicPlaybackFailure.permission => healthFailureLabel(
    l10n,
    HealthFailure.permission,
  ),
  MusicPlaybackFailure.transport => healthFailureLabel(
    l10n,
    HealthFailure.transport,
  ),
  MusicPlaybackFailure.timeout => healthFailureLabel(
    l10n,
    HealthFailure.timeout,
  ),
  MusicPlaybackFailure.unsupported => l10n.musicServiceMissing,
  MusicPlaybackFailure.sourceChanged => l10n.musicPlayChanged,
  MusicPlaybackFailure.stale ||
  MusicPlaybackFailure.invalidSelection => l10n.musicStale,
  MusicPlaybackFailure.expiredIntent ||
  MusicPlaybackFailure.invalidIntent => l10n.mediaRemoteExpired,
  MusicPlaybackFailure.busy => l10n.mediaRemoteBusy,
  MusicPlaybackFailure.unavailable ||
  MusicPlaybackFailure.invalidResponse => l10n.healthReadError,
};

class MusicPlaybackScreen extends ConsumerStatefulWidget {
  const MusicPlaybackScreen({super.key, required this.selection});
  final MusicCatalogSelection selection;
  @override
  ConsumerState<MusicPlaybackScreen> createState() =>
      _MusicPlaybackScreenState();
}

class _MusicPlaybackScreenState extends MediaSessionState<MusicPlaybackScreen> {
  bool _visible = true;
  bool _preparing = false;
  String? _error;
  Route<bool>? _confirmation;
  MusicPlaybackController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (_visible && !visible) {
      _controller?.setVisible(false);
      sessionGeneration++;
      clearPendingInteraction();
    }
    _visible = visible;
  }

  @override
  void didUpdateWidget(covariant MusicPlaybackScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.selection, widget.selection)) {
      _controller?.setVisible(false);
      sessionGeneration++;
      clearPendingInteraction();
    }
  }

  @override
  void clearPendingInteraction() {
    _controller?.setVisible(false);
    _preparing = false;
    _error = null;
    final route = _confirmation;
    _confirmation = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  @override
  void dispose() {
    _controller?.setVisible(false);
    super.dispose();
  }

  bool _current(int generation, MusicPlaybackController controller) =>
      sessionCurrent(generation) &&
      _visible &&
      identical(ref.read(musicPlaybackControllerProvider), controller) &&
      identical(
        ref.read(musicAccountGenerationProvider),
        widget.selection.accountGeneration,
      );

  Future<void> _select(MusicQueueTarget target) async {
    if (!foreground ||
        sessionExpired ||
        !_visible ||
        _preparing ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final controller = ref.read(musicPlaybackControllerProvider);
    if (controller == null) return;
    final generation = sessionGeneration;
    if (!_current(generation, controller)) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      final intent = await controller.createIntent(
        source: widget.selection,
        target: target,
      );
      if (!mounted || !_current(generation, controller)) return;
      final route = CupertinoDialogRoute<bool>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(l10n.musicPlayConfirm),
          content: Column(
            children: [
              const SizedBox(height: 12),
              Text(intent.item.name),
              Text(intent.target.name),
              const SizedBox(height: 12),
              Text(l10n.musicPlayHint),
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
              child: Text(l10n.musicPlayNow),
            ),
          ],
        ),
      );
      _confirmation = route;
      final confirmed = await Navigator.of(context).push(route);
      if (identical(_confirmation, route)) _confirmation = null;
      if (confirmed != true || !_current(generation, controller)) {
        controller.setVisible(false);
        if (_current(generation, controller)) controller.setVisible(true);
        return;
      }
      await controller.execute(intent);
    } catch (error) {
      if (_current(generation, controller)) {
        setState(
          () => _error = error is MusicPlaybackException
              ? error.outcomeUnknown
                    ? l10n.musicPlayUnknown
                    : musicPlaybackFailureLabel(l10n, error.failure)
              : l10n.healthReadError,
        );
      }
    } finally {
      if (mounted && sessionCurrent(generation)) {
        setState(() => _preparing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    watchMediaAccount(IntegrationId.ha, connectionConfigProvider);
    final l10n = AppLocalizations.of(context);
    final account = ref.watch(musicAccountGenerationProvider);
    final matchingAccount = identical(
      account,
      widget.selection.accountGeneration,
    );
    final active = foreground && !sessionExpired && _visible && matchingAccount;
    _controller = ref.watch(musicPlaybackControllerProvider);
    _controller?.setVisible(active);
    final reading = active ? ref.watch(musicDiscoveryProvider) : null;
    final discovery = reading == null || reading.isLoading || reading.hasError
        ? null
        : reading.value;
    final playback = active ? ref.watch(musicPlaybackStateProvider) : null;
    final state = playback == null || playback.isLoading || playback.hasError
        ? null
        : playback.value;
    final targets =
        discovery?.queueTargets
            .where(
              (target) =>
                  target.configEntryId == widget.selection.configEntryId,
            )
            .toList() ??
        const <MusicQueueTarget>[];
    final receipt =
        state?.receipt?.item.reference.requestValue ==
            widget.selection.item.reference.requestValue
        ? state?.receipt
        : null;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.musicPlayNow)),
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
                        if (!matchingAccount || sessionExpired)
                          Text(l10n.mediaRemoteAccountChanged)
                        else ...[
                          Text(
                            widget.selection.item.name,
                            style: AppText.title2,
                          ),
                          if (widget.selection.item.artists.isNotEmpty)
                            Text(
                              widget.selection.item.artists.join(', '),
                              style: AppText.subhead,
                            ),
                          const SizedBox(height: 12),
                          Text(l10n.musicPlayHint, style: AppText.body),
                        ],
                        const SizedBox(height: 16),
                        if (reading?.isLoading == true || _preparing)
                          const CupertinoActivityIndicator(),
                        if (reading?.hasError == true ||
                            playback?.hasError == true)
                          Text(l10n.healthReadError),
                        if (_error != null)
                          Text(_error!)
                        else if (state?.outcomeUnknown == true)
                          Text(l10n.musicPlayUnknown)
                        else if (state?.failure != null)
                          Text(
                            musicPlaybackFailureLabel(l10n, state!.failure!),
                          ),
                        if (discovery != null && targets.isEmpty)
                          Text(l10n.haMediaNoTargets),
                        CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed:
                              !active || _preparing || state?.isBusy == true
                              ? null
                              : () {
                                  if (mounted &&
                                      _visible &&
                                      foreground &&
                                      !sessionExpired) {
                                    setState(() => _error = null);
                                    ref.invalidate(musicDiscoveryProvider);
                                  }
                                },
                          child: Text(l10n.commonRefresh),
                        ),
                        if (receipt != null) ...[
                          const SizedBox(height: 12),
                          Text(receipt.target.name, style: AppText.headline),
                          Text(switch (receipt.status) {
                            MusicPlaybackReceiptStatus.accepted =>
                              l10n.musicPlayAccepted,
                            MusicPlaybackReceiptStatus.observed =>
                              l10n.musicPlayObserved,
                            MusicPlaybackReceiptStatus.unconfirmed =>
                              l10n.musicPlayUnknown,
                          }),
                        ],
                      ],
                    ),
                  ),
                ),
                SliverList.builder(
                  itemCount: targets.length,
                  itemBuilder: (context, index) {
                    final target = targets[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 6,
                      ),
                      child: CupertinoButton(
                        padding: const EdgeInsets.all(16),
                        color: CupertinoColors.secondarySystemGroupedBackground
                            .resolveFrom(context),
                        borderRadius: BorderRadius.circular(20),
                        onPressed:
                            active &&
                                !_preparing &&
                                state?.isBusy != true &&
                                target.enabled &&
                                target.available
                            ? () => _select(target)
                            : null,
                        child: Row(
                          children: [
                            const Icon(CupertinoIcons.speaker_2, size: 28),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Text(target.name, style: AppText.headline),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
