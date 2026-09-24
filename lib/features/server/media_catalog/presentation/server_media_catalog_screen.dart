import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../data/server_account_controller.dart';
import '../../media_result_origin.dart';
import '../../providers/server_providers.dart';
import '../data/server_media_catalog_cache.dart';
import '../data/server_media_catalog_controller.dart';
import '../domain/server_media_catalog_models.dart';
import '../../media_flow/data/server_media_flow_cache.dart';
import '../../media_flow/presentation/server_media_flow_screen.dart';
import '../../media_rows/data/server_media_rows_controller.dart';
import '../../media_rows/presentation/server_media_rows_section.dart';
import '../../media_rows/domain/server_media_rows_models.dart';

/// Explicit, read-only Core catalog search. It never mounts or falls back to a
/// device-local Jellyfin client.
final class ServerMediaCatalogScreen extends ConsumerStatefulWidget {
  const ServerMediaCatalogScreen({
    super.key,
    this.requestId,
    this.catalogCache,
    this.flowCache,
    this.showAccountRows = false,
  });

  @visibleForTesting
  final String Function()? requestId;

  @visibleForTesting
  final ServerMediaCatalogCache? catalogCache;

  @visibleForTesting
  final ServerMediaFlowCache? flowCache;

  final bool showAccountRows;

  @override
  ConsumerState<ServerMediaCatalogScreen> createState() =>
      _ServerMediaCatalogScreenState();
}

final class _ServerMediaCatalogScreenState
    extends ConsumerState<ServerMediaCatalogScreen>
    with WidgetsBindingObserver {
  late final ServerAccountController _account;
  late final ServerMediaCatalogController _controller;
  ServerMediaRowsController? _rowsController;
  late final int _accountGeneration;
  final _query = TextEditingController();
  ValueListenable<TickerModeData>? _ticker;
  String? _submitted;
  ServerMediaCatalogKind? _mediaKind;
  int _lifecycle = 0;
  bool _visible = true, _expired = false;

  bool get _active =>
      mounted &&
      !_expired &&
      _visible &&
      _account.isCurrent(_accountGeneration) &&
      _account.initialized &&
      !_account.working &&
      _account.session != null &&
      _account.session?.authMutationPending == false &&
      _account.session?.user.mustChangePassword == false &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _account = ref.read(serverAccountControllerProvider);
    _accountGeneration = _account.generation;
    _controller = ServerMediaCatalogController(
      _account,
      cache: widget.catalogCache,
      requestId: widget.requestId,
    );
    if (widget.showAccountRows) {
      _rowsController = ServerMediaRowsController(
        _account,
        requestId: widget.requestId,
      );
    }
    _account.addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _browse();
      _refreshRows();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticker = TickerMode.getValuesNotifier(context);
    if (!identical(ticker, _ticker)) {
      _ticker?.removeListener(_visibilityChanged);
      _ticker = ticker;
      _visible = ticker.value.enabled;
      ticker.addListener(_visibilityChanged);
    }
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountGeneration) || _account.session == null) {
      _expire();
    }
  }

  void _visibilityChanged() {
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _expire();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _expire();
  }

  void _expire() {
    if (_expired) return;
    _expired = true;
    _lifecycle++;
    _submitted = null;
    _mediaKind = null;
    _query.clear();
    _controller.retire();
    _rowsController?.retire();
  }

  bool Function() _capture() {
    final lifecycle = _lifecycle;
    return () => _active && lifecycle == _lifecycle;
  }

  void _search(String value, {int offset = 0}) {
    final current = _capture();
    if (!current() || _controller.busy) return;
    final query = value.trim();
    if (query.isEmpty || query != value || query.length > 80) return;
    setState(() => _submitted = query);
    unawaited(
      _controller.searchCurrent(
        query: query,
        mediaKind: _mediaKind,
        offset: offset,
        current: current,
      ),
    );
  }

  void _browse({int offset = 0}) {
    final current = _capture();
    if (!current() || _controller.busy) return;
    unawaited(
      _controller.browseCurrent(
        mediaKind: _mediaKind,
        offset: offset,
        current: current,
      ),
    );
  }

  void _refreshRows() {
    final current = _capture();
    final controller = _rowsController;
    if (controller == null || !current() || controller.busy) return;
    unawaited(controller.refresh(current: current));
  }

  void _selectFilter(int? value) {
    final next = switch (value) {
      1 => ServerMediaCatalogKind.movie,
      2 => ServerMediaCatalogKind.episode,
      _ => null,
    };
    if (!_active || next == _mediaKind) return;
    final query = _submitted;
    _controller.retire();
    setState(() => _mediaKind = next);
    if (query != null) {
      _search(query);
    } else {
      _browse();
    }
  }

  int get _filterValue => switch (_mediaKind) {
    ServerMediaCatalogKind.movie => 1,
    ServerMediaCatalogKind.episode => 2,
    null => 0,
  };

  void _open(ServerMediaCatalogItem item) {
    if (!_active) return;
    unawaited(
      Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => ServerMediaFlowScreen(
            mediaKey: item.flowMediaKey,
            title: item.title,
            catalogPage: _controller.page,
            catalogItem: item,
            cache: widget.flowCache,
            requestId: widget.requestId,
          ),
        ),
      ),
    );
  }

  Future<void> _openRow(ServerMediaRowItem item) async {
    final rows = _rowsController;
    final current = _capture();
    if (rows == null || !current() || rows.resolvingItemId != null) return;
    final page = await rows.resolve(item, current: current);
    if (!current() || page == null || page.items.single.itemId != item.itemId) {
      return;
    }
    final resolved = page.items.single;
    unawaited(
      Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => ServerMediaFlowScreen(
            mediaKey: resolved.flowMediaKey,
            title: resolved.title,
            catalogPage: page,
            catalogItem: resolved,
            cache: widget.flowCache,
            requestId: widget.requestId,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _controller.dispose();
    _rowsController?.dispose();
    _query.dispose();
    super.dispose();
  }

  Widget _bounded(Widget child) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1100),
      child: child,
    ),
  );

  String _kind(AppLocalizations l, ServerMediaCatalogKind kind) =>
      kind == ServerMediaCatalogKind.movie
      ? l.mediaKindMovie
      : l.mediaEpisodesTitle;

  List<Widget> _body(AppLocalizations l) {
    final page = _controller.page;
    if (_controller.busy) {
      return [
        Semantics(
          liveRegion: true,
          child: const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CupertinoActivityIndicator()),
          ),
        ),
      ];
    }
    if (_controller.failure != null) {
      return [
        Semantics(
          key: const ValueKey('server-media-catalog-cache-fallback'),
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '${l.commonError} ${l.serverMediaCacheUnavailable}',
              style: AppText.body,
            ),
          ),
        ),
      ];
    }
    if (page == null) {
      return [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _submitted == null ? l.mediaSearchPrompt : l.mediaSearchEmpty,
            style: AppText.body,
          ),
        ),
      ];
    }
    if (page.items.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l.mediaSearchEmpty, style: AppText.body),
        ),
      ];
    }
    return [
      if (_controller.origin case final origin)
        Semantics(
          key: const ValueKey('server-media-catalog-cache-origin'),
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              origin == ServerMediaResultOrigin.verifiedCache
                  ? l.serverMediaCacheVerified
                  : l.serverMediaCacheLive,
              style: AppText.footnote,
            ),
          ),
        ),
      for (final item in page.items)
        Semantics(
          key: ValueKey('server-media-catalog-item-${item.itemId}'),
          button: true,
          label: '${item.title}, ${_kind(l, item.kind)}',
          child: ExcludeSemantics(
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(48, 48),
              onPressed: _active ? () => _open(item) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(CupertinoIcons.film, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.title, style: AppText.headline),
                          const SizedBox(height: 4),
                          Text(_kind(l, item.kind), style: AppText.footnote),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(CupertinoIcons.chevron_forward, size: 18),
                  ],
                ),
              ),
            ),
          ),
        ),
      if (page.nextOffset case final offset?)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Semantics(
            key: const ValueKey('server-media-catalog-next'),
            button: true,
            label: l.commonNext,
            child: ExcludeSemantics(
              child: CupertinoButton.filled(
                minimumSize: const Size(48, 48),
                onPressed: () => _submitted == null
                    ? _browse(offset: offset)
                    : _search(_submitted!, offset: offset),
                child: Text(l.commonNext),
              ),
            ),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      return ServiceRootScaffold(
        title: l.mediaSearchTitle,
        slivers: [
          if (_rowsController case final rowsController?)
            SliverToBoxAdapter(
              child: _bounded(
                ServerMediaRowsSection(
                  controller: rowsController,
                  active: _active,
                  onRetry: _refreshRows,
                  onOpen: _openRow,
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: _bounded(
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: CupertinoSearchTextField(
                  key: const ValueKey('server-media-catalog-search-field'),
                  controller: _query,
                  placeholder: l.mediaSearchPlaceholder,
                  onSubmitted: _search,
                  enabled: _active && !_controller.busy,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _bounded(
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  child: CupertinoSlidingSegmentedControl<int>(
                    key: const ValueKey('server-media-catalog-filters'),
                    groupValue: _filterValue,
                    children: {
                      0: Padding(
                        key: const ValueKey('server-media-catalog-filter-all'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                        child: Text(l.mediaFilterAll),
                      ),
                      1: Padding(
                        key: const ValueKey(
                          'server-media-catalog-filter-movies',
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                        child: Text(l.mediaFilterMovies),
                      ),
                      2: Padding(
                        key: const ValueKey('server-media-catalog-filter-tv'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                        child: Text(l.mediaFilterTv),
                      ),
                    },
                    onValueChanged: _selectFilter,
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _bounded(
              Semantics(
                container: true,
                explicitChildNodes: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _body(l),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
