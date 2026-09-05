import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../auth/providers/auth_providers.dart';
import '../../../health/data/integration_health.dart';
import '../../../health/presentation/health_labels.dart';
import '../../hub/presentation/media_session_state.dart';
import '../data/ha_playback_controller.dart';
import '../domain/ha_media_inventory.dart';
import '../domain/ha_playback_models.dart';
import '../providers/ha_playback_providers.dart';

String haPlaybackFailureLabel(AppLocalizations l10n, HaPlaybackFailure value) =>
    switch (value) {
      HaPlaybackFailure.authentication => healthFailureLabel(
        l10n,
        HealthFailure.authentication,
      ),
      HaPlaybackFailure.permission => healthFailureLabel(
        l10n,
        HealthFailure.permission,
      ),
      HaPlaybackFailure.transport => healthFailureLabel(
        l10n,
        HealthFailure.transport,
      ),
      HaPlaybackFailure.timeout => healthFailureLabel(
        l10n,
        HealthFailure.timeout,
      ),
      HaPlaybackFailure.unavailable => l10n.mediaRemoteUnavailable,
      HaPlaybackFailure.unsupportedSource => l10n.haMediaSourceUnsupported,
      HaPlaybackFailure.unsupportedTarget => l10n.haMediaTargetUnsupported,
      HaPlaybackFailure.sourceChanged => l10n.haMediaSourceChanged,
      HaPlaybackFailure.invalidIntent ||
      HaPlaybackFailure.expiredIntent => l10n.mediaRemoteExpired,
      HaPlaybackFailure.busy => l10n.mediaRemoteBusy,
      HaPlaybackFailure.invalidResponse => l10n.healthReadError,
    };

String haMediaReceiverLabel(AppLocalizations l10n, HaMediaReceiverKind kind) =>
    switch (kind) {
      HaMediaReceiverKind.castAudio => l10n.haMediaCastAudio,
      HaMediaReceiverKind.castDisplay => l10n.haMediaCastDisplay,
      HaMediaReceiverKind.appleAudio ||
      HaMediaReceiverKind.appleTv => l10n.haMediaAppleAudio,
      HaMediaReceiverKind.audio => l10n.haMediaAudio,
      HaMediaReceiverKind.display => l10n.haMediaDisplay,
      HaMediaReceiverKind.unknown => l10n.haMediaUnknownTarget,
    };

class HaPlaybackScreen extends ConsumerStatefulWidget {
  const HaPlaybackScreen({super.key});

  @override
  ConsumerState<HaPlaybackScreen> createState() => _HaPlaybackScreenState();
}

class _HaPlaybackScreenState extends MediaSessionState<HaPlaybackScreen> {
  final _parents = <HaMediaNode>[];
  HaMediaNode? _selected;
  bool _busy = false;
  bool _tickerVisible = true;
  String? _error;
  Route<bool>? _confirmation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (_tickerVisible && !visible) {
      ref.read(haPlaybackControllerProvider)?.setVisible(false);
      sessionGeneration++;
      clearPendingInteraction();
    }
    _tickerVisible = visible;
  }

  @override
  void clearPendingInteraction() {
    _parents.clear();
    _selected = null;
    _busy = false;
    _error = null;
    final route = _confirmation;
    _confirmation = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  bool _current(int generation, HaPlaybackController controller) =>
      sessionCurrent(generation) &&
      TickerMode.valuesOf(context).enabled &&
      identical(ref.read(haPlaybackControllerProvider), controller);

  Future<void> _browse(HaMediaNode? node, {bool back = false}) async {
    if (_busy ||
        !foreground ||
        sessionExpired ||
        !_tickerVisible ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final controller = ref.read(haPlaybackControllerProvider);
    if (controller == null) return;
    final generation = sessionGeneration;
    final previousPage = ref.read(haPlaybackProvider).value?.page;
    setState(() {
      _busy = true;
      _error = null;
      _selected = null;
      if (node == null) {
        _parents.clear();
      } else if (back) {
        if (_parents.isNotEmpty) _parents.removeLast();
      } else if (previousPage != null) {
        _parents.add(previousPage.parent);
      }
    });
    try {
      await controller.browse(node);
    } catch (error) {
      if (_current(generation, controller)) {
        setState(() => _error = _failure(error));
      }
    } finally {
      if (mounted && sessionCurrent(generation)) {
        setState(() => _busy = false);
      }
    }
  }

  String _failure(Object error) {
    final l10n = AppLocalizations.of(context);
    return error is HaPlaybackException
        ? error.outcomeUnknown
              ? l10n.haMediaUnconfirmed
              : haPlaybackFailureLabel(l10n, error.failure)
        : l10n.healthReadError;
  }

  Future<void> _play(HaMediaNode source, HaMediaTarget target) async {
    if (_busy ||
        !foreground ||
        sessionExpired ||
        !_tickerVisible ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final controller = ref.read(haPlaybackControllerProvider);
    if (controller == null) return;
    final generation = sessionGeneration;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final intent = await controller.createIntent(source, target);
      if (!mounted || !_current(generation, controller)) return;
      final route = CupertinoDialogRoute<bool>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(l10n.mediaRemoteConfirm),
          content: Column(
            children: [
              const SizedBox(height: 12),
              Text('${l10n.mediaRemoteItem}: ${intent.source.title}'),
              Text('${l10n.mediaRemoteDevice}: ${intent.target.name}'),
              const SizedBox(height: 12),
              Text(l10n.haMediaReplace),
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
      if (confirmed != true || !_current(generation, controller)) {
        controller.cancelIntent();
        return;
      }
      await controller.play(intent);
    } catch (error) {
      if (_current(generation, controller)) {
        setState(() => _error = _failure(error));
      }
    } finally {
      if (mounted && sessionCurrent(generation)) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    watchMediaAccount(IntegrationId.ha, connectionConfigProvider);
    final l10n = AppLocalizations.of(context);
    // Keep the inert controller for this route. Only a visible stream consumer
    // demands reads; hiding the page invalidates pending approvals.
    final controller = ref.watch(haPlaybackControllerProvider);
    final active = foreground && !sessionExpired && _tickerVisible;
    controller?.setVisible(active);
    final reading = active ? ref.watch(haPlaybackProvider) : null;
    final snapshot = reading == null || reading.isLoading || reading.hasError
        ? null
        : reading.value;
    final page = snapshot?.page;
    final inventory = snapshot?.inventory;
    final source = _selected;
    final busy =
        _busy || snapshot?.isBusy == true || snapshot?.isLoading == true;
    final receipt = snapshot?.receipt;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.haMediaTitle)),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: CustomScrollView(
              key: const PageStorageKey('ha-media-browser'),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(CupertinoIcons.play_rectangle, size: 36),
                        const SizedBox(height: 16),
                        Text(l10n.haMediaHint, style: AppText.body),
                        const SizedBox(height: 12),
                        if (sessionExpired)
                          Text(l10n.mediaRemoteAccountChanged)
                        else if (reading?.hasError == true)
                          Text(l10n.healthReadError)
                        else if (reading?.isLoading == true ||
                            snapshot?.isLoading == true)
                          const CupertinoActivityIndicator()
                        else if (snapshot?.configured == false)
                          Text(l10n.commonNotConnected),
                        if (_error != null)
                          Text(_error!)
                        else if (snapshot?.outcomeUnknown == true)
                          Text(l10n.haMediaUnconfirmed)
                        else if (snapshot?.failure != null)
                          Text(
                            haPlaybackFailureLabel(l10n, snapshot!.failure!),
                          ),
                        if (inventory?.registryFailure != null)
                          Text(l10n.haMediaRegistryRequired),
                        if (inventory != null && !inventory.hasPlayMedia)
                          Text(l10n.haMediaServiceMissing),
                        if (inventory != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              l10n.healthLastSuccessfulRead(
                                DateFormat.yMd(l10n.localeName)
                                    .add_Hms()
                                    .format(inventory.readAt.toLocal()),
                              ),
                              style: AppText.footnote,
                            ),
                          ),
                        Wrap(
                          spacing: 16,
                          runSpacing: 4,
                          children: [
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              onPressed: !active || busy || controller == null
                                  ? null
                                  : () {
                                      setState(() {
                                        _error = null;
                                        _selected = null;
                                        _parents.clear();
                                      });
                                      controller.refresh();
                                    },
                              child: Text(l10n.commonRefresh),
                            ),
                            if (source != null)
                              CupertinoButton(
                                padding: EdgeInsets.zero,
                                onPressed: busy
                                    ? null
                                    : () => setState(() => _selected = null),
                                child: Text(l10n.haMediaChangeSource),
                              ),
                            if (page != null &&
                                source == null &&
                                _parents.isNotEmpty)
                              CupertinoButton(
                                padding: EdgeInsets.zero,
                                onPressed: busy
                                    ? null
                                    : () => _browse(_parents.last, back: true),
                                child: Text(l10n.commonBack),
                              ),
                            if (page != null &&
                                source == null &&
                                page.parent.id != 'media-source://')
                              CupertinoButton(
                                padding: EdgeInsets.zero,
                                onPressed: busy ? null : () => _browse(null),
                                child: Text(l10n.haMediaRoot),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (receipt != null)
                  SliverToBoxAdapter(
                    child: _Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(receipt.target.name, style: AppText.headline),
                          Text(receipt.source.title, style: AppText.body),
                          const SizedBox(height: 8),
                          Text(switch (receipt.status) {
                            HaPlaybackReceiptStatus.accepted =>
                              l10n.haMediaAccepted,
                            HaPlaybackReceiptStatus.observed =>
                              l10n.haMediaObserved,
                            HaPlaybackReceiptStatus.unconfirmed =>
                              l10n.haMediaUnconfirmed,
                          }),
                        ],
                      ),
                    ),
                  ),
                if (source != null && page != null && inventory != null) ...[
                  SliverToBoxAdapter(
                    child: _Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(source.title, style: AppText.title2),
                          const SizedBox(height: 8),
                          Text(l10n.haMediaTargets, style: AppText.headline),
                          const SizedBox(height: 8),
                          Text(
                            l10n.haMediaCompatibility,
                            style: AppText.footnote,
                          ),
                          if (inventory.targets.any(
                            (target) => target.platform == 'apple_tv',
                          )) ...[
                            const SizedBox(height: 8),
                            Text(
                              l10n.haMediaAppleLimit,
                              style: AppText.footnote,
                            ),
                          ],
                          if (inventory.targets.isEmpty)
                            Text(l10n.haMediaNoTargets),
                        ],
                      ),
                    ),
                  ),
                  SliverList.builder(
                    itemCount: inventory.targets.length,
                    itemBuilder: (context, index) {
                      final target = inventory.targets[index];
                      final supported = target.canPlay(source, inventory);
                      return _Panel(
                        child: CupertinoButton(
                          key: ValueKey('ha-media-target-${target.entityId}'),
                          padding: EdgeInsets.zero,
                          alignment: Alignment.centerLeft,
                          onPressed: active && !busy && supported
                              ? () => _play(source, target)
                              : null,
                          child: Row(
                            children: [
                              Icon(
                                target.isDisplay
                                    ? CupertinoIcons.tv
                                    : CupertinoIcons.speaker_2,
                                size: 28,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(target.name, style: AppText.headline),
                                    Text(
                                      haMediaReceiverLabel(
                                        l10n,
                                        target.receiverKind,
                                      ),
                                      style: AppText.subhead,
                                    ),
                                    if (!supported)
                                      Text(
                                        l10n.haMediaTargetUnsupported,
                                        style: AppText.footnote,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ] else if (page != null) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(page.parent.title, style: AppText.title2),
                          if (page.notShown > 0)
                            Text(l10n.haMediaNotShown, style: AppText.footnote),
                          if (page.children.isEmpty) Text(l10n.haMediaEmpty),
                        ],
                      ),
                    ),
                  ),
                  SliverList.builder(
                    itemCount: page.children.length,
                    itemBuilder: (context, index) {
                      final node = page.children[index];
                      return _Panel(
                        child: CupertinoButton(
                          key: ValueKey('ha-media-source-$index'),
                          padding: EdgeInsets.zero,
                          alignment: Alignment.centerLeft,
                          onPressed:
                              !active ||
                                  busy ||
                                  !(node.canExpand || node.playable)
                              ? null
                              : () {
                                  if (node.canExpand) {
                                    _browse(node);
                                  } else {
                                    setState(() {
                                      _selected = node;
                                      _error = null;
                                    });
                                  }
                                },
                          child: Row(
                            children: [
                              Icon(
                                node.canExpand
                                    ? CupertinoIcons.folder
                                    : node.isAudio
                                    ? CupertinoIcons.music_note
                                    : CupertinoIcons.film,
                                size: 28,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(node.title, style: AppText.headline),
                                    if (!node.canExpand && !node.playable)
                                      Text(
                                        l10n.haMediaSourceUnsupported,
                                        style: AppText.footnote,
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                node.canExpand
                                    ? CupertinoIcons.chevron_forward
                                    : CupertinoIcons.play_circle,
                                size: 18,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      borderRadius: BorderRadius.circular(20),
    ),
    child: child,
  );
}
