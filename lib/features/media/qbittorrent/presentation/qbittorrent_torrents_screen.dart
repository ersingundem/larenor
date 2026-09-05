import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qbittorrent_api/qbittorrent_api.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/direct_home_access.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/widgets/operational_service_scope.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../health/data/action_receipt.dart';
import '../../../health/data/integration_health.dart';
import '../../../health/providers/action_providers.dart';
import '../../data/media_api_exception.dart';
import '../../hub/presentation/media_session_state.dart';
import '../data/qbittorrent_client.dart';
import '../providers/qbittorrent_providers.dart';
import 'add_torrent_sheet.dart';
import 'qbittorrent_connect_screen.dart';

class QbittorrentTorrentsScreen extends ConsumerStatefulWidget {
  const QbittorrentTorrentsScreen({super.key});
  @override
  ConsumerState<QbittorrentTorrentsScreen> createState() =>
      _QbittorrentTorrentsScreenState();
}

class _QbittorrentTorrentsScreenState
    extends MediaSessionState<QbittorrentTorrentsScreen> {
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  bool _visible = true;
  bool _hasAccount = false;
  bool _pending = false;
  bool _dispatched = false;
  bool _uncertain = false;
  String? _message;
  Route<dynamic>? _modal;

  bool get _viewCurrent =>
      TickerMode.valuesOf(context).enabled &&
      ((ModalRoute.of(context)?.isCurrent ?? true) ||
          _modal?.isCurrent == true);

  bool _current(int generation) =>
      sessionCurrent(generation) && _access.isCurrent && _viewCurrent;

  VoidCallback _guardedAction(VoidCallback action) {
    final generation = sessionGeneration;
    return () {
      if (_current(generation)) action();
    };
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = _viewCurrent;
    if (_visible && !visible) {
      sessionGeneration++;
      clearPendingInteraction();
    }
    _visible = visible;
  }

  QbittorrentClient? get _client {
    final state = ref.read(qbittorrentClientProvider);
    return state.isLoading || state.hasError ? null : state.value;
  }

  bool Function()? _capture(QbittorrentClient client) {
    final generation = sessionGeneration;
    if (!_current(generation) || !identical(_client, client)) return null;
    return () => _current(generation) && identical(_client, client);
  }

  @override
  void clearPendingInteraction() {
    // Retain the overall busy guard until the old future settles. In
    // particular a system picker must not allow a second parallel add flow.
    if (_dispatched) _uncertain = true;
    _message = null;
    final route = _modal;
    _modal = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  Future<T?> _showModal<T>(WidgetBuilder builder, {bool popup = false}) async {
    if (!mounted || !foreground || sessionExpired || _modal != null) {
      return null;
    }
    final route = popup
        ? CupertinoModalPopupRoute<T>(builder: builder)
        : CupertinoDialogRoute<T>(context: context, builder: builder);
    _modal = route;
    try {
      return await Navigator.of(context).push<T>(route);
    } finally {
      if (identical(_modal, route)) _modal = null;
    }
  }

  Future<void> _refresh() async {
    final client = _client;
    final current = client == null ? null : _capture(client);
    if (_pending || current == null) return;
    setState(() => _pending = true);
    try {
      ref.invalidate(qbittorrentTorrentsProvider);
      await ref.read(qbittorrentTorrentsProvider.future);
      if (current()) {
        setState(() {
          _uncertain = false;
          _message = null;
        });
      }
    } catch (_) {
      if (current()) {
        setState(() => _message = AppLocalizations.of(context).healthReadError);
      }
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  Future<void> _execute({
    required String target,
    required String action,
    required bool Function() current,
    required Future<void> Function() send,
  }) async {
    if (!current()) return;
    _dispatched = true;
    final receipt = await ref
        .read(actionControllerProvider)
        .execute<void>(
          key: ActionKey(
            integration: IntegrationId.qbittorrent,
            target: target,
            action: action,
          ),
          send: () async {
            if (!current()) throw StateError('Expired torrent action');
            await send();
          },
          classifyFailure: (error) => switch (error) {
            MediaApiException(statusCode: 401) => ActionFailure.authentication,
            MediaApiException(statusCode: 403) => ActionFailure.permission,
            MediaApiException(statusCode: final int code)
                when code >= 400 && code < 500 =>
              ActionFailure.rejected,
            _ => ActionFailure.unknown,
          },
        );
    if (!mounted || !current()) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _uncertain = receipt.status == ActionStatus.unknown;
      _message = switch (receipt.status) {
        ActionStatus.accepted ||
        ActionStatus.confirmed => l10n.qbittorrentActionAccepted,
        ActionStatus.unknown => l10n.qbittorrentActionUnknown,
        _ => l10n.actionFailed,
      };
    });
    if (!_uncertain) ref.invalidate(qbittorrentTorrentsProvider);
  }

  Future<void> _add() async {
    final client = _client;
    if (_pending ||
        _uncertain ||
        client == null ||
        !client.isAuthenticated ||
        _capture(client) == null) {
      return;
    }
    setState(() {
      _pending = true;
      _message = null;
    });
    try {
      final intent = await showAddTorrentSheet(
        context,
        showModal: _showModal,
        captureIntent: () => _capture(client),
        fileAccess: ref.read(torrentFileAccessProvider),
      );
      if (!mounted || intent == null || !intent.isCurrent()) return;
      await _execute(
        target: 'add',
        action: 'add',
        current: intent.isCurrent,
        send: () => client.torrents.addNewTorrents(torrents: intent.torrents),
      );
    } catch (_) {
      if (mounted && _capture(client) != null) {
        setState(
          () => _message = _dispatched
              ? AppLocalizations.of(context).qbittorrentActionUnknown
              : AppLocalizations.of(context).qbittorrentFileError,
        );
        if (_dispatched) _uncertain = true;
      }
    } finally {
      _dispatched = false;
      if (mounted) setState(() => _pending = false);
    }
  }

  Future<void> _showActions(TorrentInfo torrent) async {
    if (!mounted) return;
    final reading = ref.read(qbittorrentTorrentsProvider);
    if (reading.isLoading || reading.hasError) return;
    final client = _client;
    final hash = torrent.hash;
    if (_pending ||
        _uncertain ||
        client == null ||
        !client.isAuthenticated ||
        !_validHash(hash)) {
      return;
    }
    final current = _capture(client);
    if (current == null) return;
    setState(() {
      _pending = true;
      _message = null;
    });
    try {
      final action = await _showModal<String>(
        (context) => CupertinoActionSheet(
          title: Text(
            torrent.name ??
                AppLocalizations.of(context).qbittorrentTileFallbackName,
          ),
          actions: [
            for (final action in ['pause', 'resume', 'delete'])
              CupertinoActionSheetAction(
                key: ValueKey('torrent-action-$action'),
                isDestructiveAction: action == 'delete',
                onPressed: () => closeTorrentModal(context, action),
                child: Text(switch (action) {
                  'pause' => AppLocalizations.of(
                    context,
                  ).qbittorrentPauseAction,
                  'resume' => AppLocalizations.of(
                    context,
                  ).qbittorrentResumeAction,
                  _ => AppLocalizations.of(context).commonDelete,
                }),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => closeTorrentModal(context),
            child: Text(AppLocalizations.of(context).commonCancel),
          ),
        ),
        popup: true,
      );
      if (!current() || action == null) return;
      if (action == 'delete') {
        final confirmed = await _showModal<bool>(
          (context) => CupertinoAlertDialog(
            title: Text(AppLocalizations.of(context).commonDelete),
            content: Text(
              AppLocalizations.of(context).qbittorrentDeleteConfirmation(
                torrent.name ??
                    AppLocalizations.of(context).qbittorrentTileFallbackName,
              ),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => closeTorrentModal(context, false),
                child: Text(AppLocalizations.of(context).commonCancel),
              ),
              CupertinoDialogAction(
                key: const ValueKey('torrent-confirm-delete'),
                isDestructiveAction: true,
                onPressed: () => closeTorrentModal(context, true),
                child: Text(AppLocalizations.of(context).commonDelete),
              ),
            ],
          ),
        );
        if (!current() || confirmed != true) return;
      }
      final selected = Torrents(hashes: [hash!]);
      await _execute(
        target: hash,
        action: action,
        current: current,
        send: () => switch (action) {
          'pause' => client.torrents.pauseTorrents(torrents: selected),
          'resume' => client.torrents.resumeTorrents(torrents: selected),
          'delete' => client.torrents.deleteTorrents(
            torrents: selected,
            deleteFiles: false,
          ),
          _ => Future<void>.error(StateError('Invalid torrent action')),
        },
      );
    } catch (_) {
      if (current()) {
        setState(() {
          _uncertain = _dispatched;
          _message = _dispatched
              ? AppLocalizations.of(context).qbittorrentActionUnknown
              : AppLocalizations.of(context).actionFailed;
        });
      }
    } finally {
      _dispatched = false;
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(directHomeAccessProvider);
    final connection = ref.watch(qbittorrentConnectionProvider);
    if (!connection.isLoading &&
        !connection.hasError &&
        connection.value != null)
      _hasAccount = true;
    if (_hasAccount)
      watchMediaAccount(
        IntegrationId.qbittorrent,
        qbittorrentConnectionProvider,
      );
    final l10n = AppLocalizations.of(context);
    if (!foreground || sessionExpired || !_access.isCurrent) {
      return CupertinoPageScaffold(
        child: !foreground
            ? const SizedBox.expand()
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(l10n.mediaAccountChanged),
                ),
              ),
      );
    }
    final error = connection.error;
    final recovery =
        error is DirectHomeAccessException &&
        {'pending_mutation', 'write_unconfirmed'}.contains(error.code);
    if (!connection.isLoading &&
        OperationalServiceScope.maybeOf(context) == null &&
        (recovery || !connection.hasError && connection.value == null)) {
      return QbittorrentConnectScreen(
        key: ValueKey(recovery),
        recovery: recovery,
        popOnSuccess: false,
      );
    }
    final torrents = ref.watch(qbittorrentTorrentsProvider);
    final client = ref.watch(qbittorrentClientProvider);
    final ready =
        !client.isLoading &&
        !client.hasError &&
        client.value?.isAuthenticated == true;
    final generation = sessionGeneration;
    final message =
        _message ?? (_uncertain ? l10n.qbittorrentActionUnknown : null);
    return ServiceRootScaffold(
      title: 'qBittorrent',
      leading: CupertinoButton(
        key: const ValueKey('torrent-refresh'),
        padding: EdgeInsets.zero,
        onPressed: _pending
            ? null
            : _guardedAction(() {
                if (ready) {
                  _refresh();
                } else {
                  ref.invalidate(qbittorrentClientProvider);
                  ref.invalidate(qbittorrentTorrentsProvider);
                }
              }),
        child: const Icon(CupertinoIcons.refresh),
      ),
      trailing: CupertinoButton(
        key: const ValueKey('torrent-add'),
        padding: EdgeInsets.zero,
        onPressed: _pending || _uncertain || !ready
            ? null
            : _guardedAction(_add),
        child: const Icon(CupertinoIcons.add),
      ),
      slivers: [
        if (message != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Semantics(liveRegion: true, child: Text(message)),
            ),
          ),
        if (connection.hasError)
          SliverFilledMessage(child: Text(l10n.healthReadError))
        else
          ...torrents.when(
            skipLoadingOnRefresh: false,
            skipLoadingOnReload: false,
            loading: () => const [
              SliverFilledMessage(child: CupertinoActivityIndicator()),
            ],
            error: (_, _) => [
              SliverFilledMessage(child: Text(l10n.healthReadError)),
            ],
            data: (items) => items.isEmpty
                ? [SliverFilledMessage(child: Text(l10n.qbittorrentNoTorrents))]
                : [
                    SliverPadding(
                      padding: const EdgeInsets.all(Gap.lg),
                      sliver: SliverList.builder(
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final torrent = items[index];
                          return CupertinoListTile(
                            key: ValueKey('torrent-row-$index'),
                            backgroundColor: CupertinoColors
                                .secondarySystemGroupedBackground
                                .resolveFrom(context),
                            title: Text(
                              torrent.name ?? l10n.commonUnknown,
                              maxLines: 2,
                            ),
                            subtitle: Text(
                              '${torrent.state?.name ?? l10n.commonUnknown} · ${torrentProgressLabel(l10n, torrent.progress)}',
                            ),
                            trailing: const CupertinoListTileChevron(),
                            onTap:
                                _pending ||
                                    _uncertain ||
                                    !ready ||
                                    !_validHash(torrent.hash)
                                ? null
                                : () {
                                    if (_current(generation) &&
                                        identical(
                                          ref
                                              .read(qbittorrentTorrentsProvider)
                                              .value,
                                          items,
                                        )) {
                                      _showActions(torrent);
                                    }
                                  },
                          );
                        },
                      ),
                    ),
                  ],
          ),
      ],
    );
  }
}

bool _validHash(String? hash) =>
    hash != null &&
    RegExp(r'^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$').hasMatch(hash);

String torrentProgressLabel(AppLocalizations l10n, double? progress) =>
    progress == null || !progress.isFinite
    ? l10n.mediaProgressUnknown
    : '${(progress.clamp(0.0, 1.0) * 100).round()}%';
