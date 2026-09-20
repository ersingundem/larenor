import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/trust_evidence_card.dart';
import '../../core_ha/presentation/core_ha_screen.dart';
import '../../core_proxmox/presentation/core_proxmox_screen.dart';
import '../../keenetic/core/presentation/core_keenetic_screen.dart';
import '../../server/providers/server_providers.dart';
import '../data/home_resources_api.dart';
import '../data/home_resources_controller.dart';
import '../data/core_bounded_download_api.dart';
import '../data/core_bounded_download_controller.dart';
import '../data/core_bounded_download_file_access.dart';
import '../data/core_bounded_upload_file_access.dart';
import '../domain/home_resource_models.dart';
import '../../settings/presentation/settings_gate_screen.dart';

/// Shared Core metadata; a selected resource explicitly opens its state route.
class CoreHomeResources extends ConsumerStatefulWidget {
  const CoreHomeResources({super.key});
  @override
  ConsumerState<CoreHomeResources> createState() => _CoreHomeResourcesState();
}

class _CoreHomeResourcesState extends ConsumerState<CoreHomeResources>
    with WidgetsBindingObserver {
  late final HomeResourcesController _controller;
  late final CoreBoundedDownloadController _download;
  bool _foreground = true, _focused = true, _scheduled = false;
  int? _viewId;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _controller = HomeResourcesController(
      ref.read(homeSessionControllerProvider)!,
      ref.read(homeResourcesApiFactoryProvider),
      ref.read(homeResourcesClockProvider),
      _current,
    );
    _download = CoreBoundedDownloadController(
      ref.read(homeSessionControllerProvider)!,
      ref.read(coreBoundedDownloadApiFactoryProvider),
      ref.read(coreBoundedDownloadFileAccessProvider),
      ref.read(homeResourcesClockProvider),
      _current,
      ref.read(coreBoundedUploadFileAccessProvider),
    );
    _controller.addListener(_resourceAuthorityChanged);
  }

  void _resourceAuthorityChanged() =>
      _download.retainAuthority(_controller.entries, _controller.userRevision);

  Widget _transferTrust(HomeResourceRecord entry, AppLocalizations l10n) {
    final phase = _download.phase;
    final phaseLabel = switch (phase) {
      CoreBoundedDownloadPhase.downloading => l10n.coreResourceDownloading,
      CoreBoundedDownloadPhase.choosingDestination =>
        l10n.coreResourceChooseDestination,
      CoreBoundedDownloadPhase.saved => l10n.coreResourceDownloadSaved,
      CoreBoundedDownloadPhase.cancelled => l10n.coreResourceDownloadCancelled,
      CoreBoundedDownloadPhase.unauthorized =>
        l10n.coreResourceDownloadSessionLost,
      CoreBoundedDownloadPhase.forbidden => l10n.coreResourceDownloadForbidden,
      CoreBoundedDownloadPhase.changed => l10n.coreResourceDownloadChanged,
      CoreBoundedDownloadPhase.lateFrame ||
      CoreBoundedDownloadPhase.failed => l10n.coreResourceDownloadFailed,
      CoreBoundedDownloadPhase.idle => '',
    };
    final receipt = _download.receipt;
    final complete = _download.deviceResultObserved;
    final checking =
        phase == CoreBoundedDownloadPhase.downloading ||
        phase == CoreBoundedDownloadPhase.choosingDestination;
    final evidence = [
      l10n.coreTransferEvidenceIntentRegistered,
      _download.serviceReachable
          ? l10n.coreTransferEvidenceServiceReachable
          : l10n.coreTransferEvidenceServiceUnverified,
      _download.providerAccepted
          ? l10n.coreTransferEvidenceProviderAccepted
          : l10n.coreTransferEvidenceProviderUnverified,
      complete
          ? l10n.coreTransferEvidenceDeviceSaved
          : l10n.coreTransferEvidenceDeviceMissing,
    ].join('\n');
    final body = switch ((complete, _download.providerAccepted)) {
      (true, _) => l10n.coreTransferTrustVerifiedBody,
      (false, true) => l10n.coreTransferTrustIncompleteBody,
      _ when checking => l10n.coreTransferTrustCheckingBody,
      _ => l10n.coreTransferTrustUnverifiedBody,
    };
    return TrustEvidenceCard(
      key: ValueKey('core-resource-transfer-trust-${entry.id}'),
      state: complete
          ? TrustEvidenceState.verified
          : checking
          ? TrustEvidenceState.checking
          : TrustEvidenceState.actionRequired,
      title: complete
          ? l10n.coreTransferTrustVerified
          : checking
          ? phase == CoreBoundedDownloadPhase.choosingDestination
                ? l10n.coreTransferTrustAwaitingDevice
                : l10n.coreTransferTrustChecking
          : _download.providerAccepted
          ? l10n.coreTransferTrustIncomplete
          : l10n.coreTransferTrustUnverified,
      body: '$body $phaseLabel\n$evidence',
      detail: receipt == null
          ? null
          : l10n.coreTransferTrustDetail(
              '${receipt.requestId.substring(0, 8)}…',
              receipt.contentLength,
            ),
    );
  }

  Widget _uploadStatus(HomeResourceRecord entry, AppLocalizations l10n) {
    final descriptor = _download.descriptor;
    final label = switch (_download.uploadPhase) {
      CoreBoundedUploadPhase.choosingSource => l10n.coreResourceUploadChoosing,
      CoreBoundedUploadPhase.uploading => l10n.coreResourceUploading,
      CoreBoundedUploadPhase.uploaded when descriptor != null =>
        l10n.coreResourceUploadComplete(
          descriptor.contentLength,
          descriptor.serviceRevision,
        ),
      CoreBoundedUploadPhase.cancelled => l10n.coreResourceUploadCancelled,
      CoreBoundedUploadPhase.unauthorized => l10n.coreResourceUploadSessionLost,
      CoreBoundedUploadPhase.forbidden => l10n.coreResourceUploadForbidden,
      CoreBoundedUploadPhase.changed => l10n.coreResourceUploadChanged,
      CoreBoundedUploadPhase.failed ||
      CoreBoundedUploadPhase.uploaded => l10n.coreResourceUploadFailed,
      CoreBoundedUploadPhase.idle => '',
    };
    return Semantics(
      liveRegion: _download.uploadPhase != CoreBoundedUploadPhase.cancelled,
      child: Text(
        label,
        key: ValueKey('core-resource-upload-status-${entry.id}'),
      ),
    );
  }

  bool _current() =>
      mounted &&
      identical(ref.read(homeSessionControllerProvider), _controller.home) &&
      _foreground &&
      _focused &&
      _windowAvailable() &&
      (AppInteractionScope.maybeRead(context)?.active ?? true) &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true;
  bool _windowAvailable() {
    final reading = ref.read(windowPolicySnapshotProvider);
    if (reading.isLoading || reading.hasError || !reading.hasValue) {
      return false;
    }
    final window = reading.requireValue;
    return !window.supported ||
        (window.isResumed &&
            window.hasWindowFocus &&
            !window.isPictureInPicture);
  }

  void _windowChanged() {
    if (!_windowAvailable()) _generation++;
    _controller.setVisible(_current());
    _download.setVisible(_current());
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId != _viewId) return;
    _focused = event.state == ViewFocusState.focused;
    if (!_focused) _generation++;
    _controller.setVisible(_current());
    _download.setVisible(_current());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewId = View.of(context).viewId;
    AppInteractionScope.maybeOf(context);
    TickerMode.valuesOf(context);
    ModalRoute.of(context);
    _syncLater();
  }

  void _syncLater() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) {
        _controller.setVisible(_current());
        _download.setVisible(_current());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _generation++;
    _controller.setVisible(_current());
    _download.setVisible(_current());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_resourceAuthorityChanged);
    _controller.dispose();
    _download.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(homeSessionControllerProvider);
    ref.listen(windowPolicySnapshotProvider, (_, _) => _windowChanged());
    _syncLater();
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_controller, _download]),
      builder: (_, _) {
        if (!_current()) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        final epoch = _controller.epoch, generation = _generation;
        final interaction = AppInteractionScope.maybeRead(context),
            interactionEpoch = interaction?.epoch;
        bool current() =>
            _current() &&
            epoch == _controller.epoch &&
            generation == _generation &&
            identical(interaction, AppInteractionScope.maybeRead(context)) &&
            interaction?.epoch == interactionEpoch;
        Widget button(
          String key,
          String label,
          bool enabled,
          Future<void> Function() action,
        ) => CupertinoButton(
          key: ValueKey(key),
          minimumSize: const Size(48, 48),
          focusColor: CupertinoTheme.of(context).primaryColor,
          onPressed: !enabled
              ? null
              : () {
                  if (current()) unawaited(action());
                },
          child: Text(label, textAlign: TextAlign.center),
        );
        final visibleEntries = _controller.fresh
            ? (_controller.entries.toList()..sort((a, b) {
                final order = a.order.compareTo(b.order);
                return order == 0 ? a.id.compareTo(b.id) : order;
              }))
            : const <HomeResourceRecord>[];
        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.homeResourcesTitle,
                      style: CupertinoTheme.of(context)
                          .textTheme
                          .navTitleTextStyle,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(l10n.homeResourcesDescription),
                  const SizedBox(height: 8),
                  button(
                    'home-resources-refresh',
                    l10n.commonRefresh,
                    _controller.canRefresh,
                    _controller.refresh,
                  ),
                  if (_controller.canManage)
                    button(
                      'home-resources-manage',
                      l10n.homeResourceAdminManage,
                      true,
                      () async {
                        if (!current() || !_controller.canManage) return;
                        await Navigator.of(context).push<void>(
                          CupertinoPageRoute(
                            builder: (_) => const SettingsGateScreen(
                              initialDestination:
                                  SettingsGateDestination.homeResources,
                            ),
                          ),
                        );
                      },
                    ),
                  if (_controller.busy)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.homeResourcesLoading,
                        key: const ValueKey('home-resources-loading'),
                      ),
                    )
                  else if (!_controller.fresh)
                    Text(l10n.homeCoreVerificationRequired)
                  else if (_controller.failure != null)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.homeResourcesError,
                        key: const ValueKey('home-resources-error'),
                      ),
                    )
                  else if (_controller.loaded && visibleEntries.isEmpty)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.homeResourcesEmpty,
                        key: const ValueKey('home-resources-empty'),
                      ),
                    ),
                ],
              ),
            ),
            SliverList.builder(
              key: const ValueKey('home-resources-list'),
              itemCount: visibleEntries.length,
              findChildIndexCallback: (key) {
                final index = visibleEntries.indexWhere(
                  (entry) => key == ValueKey('home-resource-${entry.id}'),
                );
                return index < 0 ? null : index;
              },
              itemBuilder: (context, index) {
                final entry = visibleEntries[index];
                final kind = entry.kind == HomeResourceKind.room
                    ? l10n.homeResourcesRoom
                    : l10n.homeResourcesResource;
                return Padding(
                  key: ValueKey('home-resource-${entry.id}'),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Semantics(
                    container: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.label,
                          style: CupertinoTheme.of(context).textTheme.textStyle
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(kind),
                        if (entry.kind == HomeResourceKind.resource) ...[
                          button(
                            'core-ha-open-${entry.id}',
                            '${l10n.coreHaOpen}: ${entry.label}',
                            true,
                            () async {
                              if (!current()) return;
                              await Navigator.of(context).push<void>(
                                CupertinoPageRoute(
                                  builder: (_) => CoreHaScreen(target: entry),
                                ),
                              );
                            },
                          ),
                          button(
                            'core-keenetic-open-${entry.id}',
                            '${l10n.coreKeeneticOpen}: ${entry.label}',
                            true,
                            () async {
                              if (!current()) return;
                              final session = ref
                                  .read(serverAccountControllerProvider)
                                  .session;
                              await Navigator.of(context).push<void>(
                                CupertinoPageRoute(
                                  builder: (_) => CoreKeeneticScreen(
                                    target: entry,
                                    admin: session?.user.canAdminister == true,
                                  ),
                                ),
                              );
                            },
                          ),
                          button(
                            'core-proxmox-open-${entry.id}',
                            '${l10n.coreProxmoxOpen}: ${entry.label}',
                            true,
                            () async {
                              if (!current()) return;
                              await Navigator.of(context).push<void>(
                                CupertinoPageRoute(
                                  builder: (_) =>
                                      CoreProxmoxScreen(target: entry),
                                ),
                              );
                            },
                          ),
                          button(
                            'core-resource-download-${entry.id}',
                            '${l10n.coreResourceDownload}: ${entry.label}',
                            _download.canDownload(
                              entry,
                              _controller.userRevision,
                            ),
                            () => _download.download(
                              entry,
                              userRevision: _controller.userRevision!,
                              isCurrent: current,
                            ),
                          ),
                          if (entry.canWrite)
                            button(
                              'core-resource-upload-${entry.id}',
                              '${l10n.coreResourceUpload}: ${entry.label}',
                              _download.canUpload(
                                entry,
                                _controller.userRevision,
                              ),
                              () => _download.chooseAndUpload(
                                entry,
                                userRevision: _controller.userRevision!,
                                isCurrent: _current,
                              ),
                            ),
                          button(
                            'core-resource-transfer-history-${entry.id}',
                            '${l10n.coreResourceTransferHistory}: ${entry.label}',
                            _download.canLoadHistory(entry),
                            () => _download.loadHistory(
                              entry,
                              isCurrent: current,
                            ),
                          ),
                          if (_download.targetId == entry.id &&
                              _download.phase != CoreBoundedDownloadPhase.idle)
                            _transferTrust(entry, l10n),
                          if (_download.uploadTargetId == entry.id &&
                              _download.uploadPhase !=
                                  CoreBoundedUploadPhase.idle)
                            _uploadStatus(entry, l10n),
                          if (_download.historyTargetId == entry.id)
                            Semantics(
                              liveRegion:
                                  _download.historyPhase ==
                                      CoreBoundedHistoryPhase.loading ||
                                  _download.historyPhase ==
                                      CoreBoundedHistoryPhase.failed,
                              child: switch (_download.historyPhase) {
                                CoreBoundedHistoryPhase.loading => Text(
                                  l10n.coreResourceTransferHistoryLoading,
                                  key: ValueKey(
                                    'core-resource-transfer-history-loading-${entry.id}',
                                  ),
                                ),
                                CoreBoundedHistoryPhase.ready
                                    when _download.history.isEmpty =>
                                  Text(
                                    l10n.coreResourceTransferHistoryEmpty,
                                    key: ValueKey(
                                      'core-resource-transfer-history-empty-${entry.id}',
                                    ),
                                  ),
                                CoreBoundedHistoryPhase.ready => Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    for (final receipt in _download.history)
                                      Padding(
                                        key: ValueKey(
                                          'core-resource-transfer-receipt-${receipt.requestId}',
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 6,
                                        ),
                                        child: Semantics(
                                          container: true,
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                switch (receipt.state) {
                                                  CoreBoundedTransferState
                                                      .accepted =>
                                                    l10n.coreResourceTransferAccepted,
                                                  CoreBoundedTransferState
                                                      .completed =>
                                                    l10n.coreResourceTransferCompleted,
                                                  CoreBoundedTransferState
                                                      .interrupted =>
                                                    l10n.coreResourceTransferInterrupted,
                                                },
                                                style:
                                                    CupertinoTheme.of(context)
                                                        .textTheme
                                                        .textStyle
                                                        .copyWith(
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                '${receipt.contentLength} B · ${receipt.contentType}',
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                CoreBoundedHistoryPhase.idle =>
                                  const SizedBox.shrink(),
                                CoreBoundedHistoryPhase.cancelled ||
                                CoreBoundedHistoryPhase.unauthorized ||
                                CoreBoundedHistoryPhase.forbidden ||
                                CoreBoundedHistoryPhase.changed ||
                                CoreBoundedHistoryPhase.failed => Text(
                                  l10n.coreResourceTransferHistoryFailed,
                                  key: ValueKey(
                                    'core-resource-transfer-history-error-${entry.id}',
                                  ),
                                ),
                              },
                            ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
            if (_controller.nextAfter != null)
              SliverToBoxAdapter(
                child: button(
                  'home-resources-load-more',
                  l10n.homeResourcesLoadMore,
                  _controller.canLoadMore,
                  _controller.loadMore,
                ),
              ),
          ],
        );
      },
    );
  }
}
