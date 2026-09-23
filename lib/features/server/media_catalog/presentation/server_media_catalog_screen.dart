import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_media_catalog_controller.dart';
import '../domain/server_media_catalog_models.dart';

/// Explicit, read-only Core catalog search. It never mounts or falls back to a
/// device-local Jellyfin client.
final class ServerMediaCatalogScreen extends ConsumerStatefulWidget {
  const ServerMediaCatalogScreen({super.key, this.requestId});

  @visibleForTesting
  final String Function()? requestId;

  @override
  ConsumerState<ServerMediaCatalogScreen> createState() =>
      _ServerMediaCatalogScreenState();
}

final class _ServerMediaCatalogScreenState
    extends ConsumerState<ServerMediaCatalogScreen>
    with WidgetsBindingObserver {
  late final ServerAccountController _account;
  late final ServerMediaCatalogController _controller;
  late final int _accountGeneration;
  final _query = TextEditingController();
  ValueListenable<TickerModeData>? _ticker;
  String? _submitted;
  int _lifecycle = 0;
  bool _visible = true, _expired = false;

  bool get _active =>
      mounted &&
      !_expired &&
      _visible &&
      _account.isCurrent(_accountGeneration) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _account = ref.read(serverAccountControllerProvider);
    _accountGeneration = _account.generation;
    _controller = ServerMediaCatalogController(
      _account,
      requestId: widget.requestId,
    );
    _account.addListener(_accountChanged);
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
    if (!_account.isCurrent(_accountGeneration) ||
        _account.session?.user.canAdminister != true) {
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
    _query.clear();
    _controller.retire();
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
      _controller.searchCurrent(query: query, offset: offset, current: current),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _controller.dispose();
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
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l.commonError, style: AppText.body),
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
      for (final item in page.items)
        Semantics(
          key: ValueKey('server-media-catalog-item-${item.itemId}'),
          label: '${item.title}, ${_kind(l, item.kind)}',
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
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
                ],
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
                onPressed: _submitted == null
                    ? null
                    : () => _search(_submitted!, offset: offset),
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
