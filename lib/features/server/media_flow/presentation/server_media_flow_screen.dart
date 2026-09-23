import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../data/server_account_controller.dart';
import '../../media_catalog/domain/server_media_catalog_models.dart';
import '../../media_playback/data/server_media_playback_controller.dart';
import '../../media_playback/domain/server_media_playback_models.dart';
import '../../providers/server_providers.dart';
import '../data/server_media_flow_controller.dart';
import '../domain/server_media_flow_models.dart';

/// Read-only, lifecycle-bound evidence for one central Core media flow.
final class ServerMediaFlowScreen extends ConsumerStatefulWidget {
  const ServerMediaFlowScreen({
    super.key,
    required this.mediaKey,
    required this.title,
    this.catalogPage,
    this.catalogItem,
    this.requestId,
  }) : assert(
         (catalogPage == null) == (catalogItem == null),
         'catalogPage and catalogItem must be provided together',
       );

  final String mediaKey, title;
  final ServerMediaCatalogPage? catalogPage;
  final ServerMediaCatalogItem? catalogItem;

  @visibleForTesting
  final String Function()? requestId;

  @override
  ConsumerState<ServerMediaFlowScreen> createState() =>
      _ServerMediaFlowScreenState();
}

final class _ServerMediaFlowScreenState
    extends ConsumerState<ServerMediaFlowScreen>
    with WidgetsBindingObserver {
  late final ServerAccountController _account;
  late final ServerMediaFlowController _controller;
  late final ServerMediaPlaybackController? _playback;
  late final int _accountGeneration;
  ValueListenable<TickerModeData>? _ticker;
  int _lifecycle = 0;
  bool _visible = true, _expired = false, _scheduled = false;

  bool get _active =>
      mounted &&
      !_expired &&
      _visible &&
      _account.isCurrent(_accountGeneration) &&
      _account.initialized &&
      !_account.working &&
      !_account.hasPendingContext &&
      _account.session != null &&
      _account.session?.authMutationPending == false &&
      _account.session?.user.mustChangePassword == false &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  bool get _canReadFlow => _account.session?.user.canAdminister == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _account = ref.read(serverAccountControllerProvider);
    _accountGeneration = _account.generation;
    _controller = ServerMediaFlowController(
      _account,
      requestId: widget.requestId,
    );
    _playback = widget.catalogPage == null
        ? null
        : ServerMediaPlaybackController(_account, requestId: widget.requestId);
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
    if (!_scheduled) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountGeneration) || !_active) {
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
    _controller.retire();
    _playback?.retire();
  }

  bool Function() _capture() {
    final lifecycle = _lifecycle;
    return () => _active && lifecycle == _lifecycle;
  }

  void _load() {
    final current = _capture();
    if (!current() || !_canReadFlow || _controller.busy) return;
    unawaited(_controller.load(widget.mediaKey, current: current));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _controller.dispose();
    _playback?.dispose();
    super.dispose();
  }

  String _stageName(AppLocalizations l, String name) => switch (name) {
    'request' => l.mediaStatusRequested,
    'download' => l.mediaStatusDownloading,
    'import' => l.mediaStatusImporting,
    _ => l.mediaStatusAvailable,
  };

  String _stageState(AppLocalizations l, ServerMediaFlowStage stage) =>
      switch (stage.state) {
        'not_started' => l.mediaStatusUnknown,
        'pending' => l.mediaStatusQueued,
        'active' => _stageName(l, stage.name),
        'partial' => l.mediaStatusPartiallyAvailable,
        'complete' => l.mediaStatusAvailable,
        _ => l.mediaStatusFailed,
      };

  String _status(AppLocalizations l, String state) => switch (state) {
    'requested' => l.mediaStatusRequested,
    'downloading' => l.mediaStatusDownloading,
    'importing' => l.mediaStatusImporting,
    'partial' => l.mediaStatusPartiallyAvailable,
    'playable' => l.mediaStatusInLibrary,
    'failed' => l.mediaStatusFailed,
    _ => l.mediaStatusUnknown,
  };

  Widget _stage(AppLocalizations l, ServerMediaFlowStage stage) {
    final name = _stageName(l, stage.name);
    final state = _stageState(l, stage);
    return Semantics(
      key: ValueKey('server-media-flow-stage-${stage.name}'),
      container: true,
      label: '$name, $state, ${stage.provider}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                stage.state == 'complete'
                    ? CupertinoIcons.check_mark_circled_solid
                    : stage.state == 'failed'
                    ? CupertinoIcons.exclamationmark_triangle_fill
                    : CupertinoIcons.clock,
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: AppText.headline),
                    const SizedBox(height: 4),
                    Text(state, style: AppText.body),
                    const SizedBox(height: 4),
                    Text(stage.provider, style: AppText.footnote),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _body(AppLocalizations l) {
    if (!_canReadFlow) return const [];
    if (_controller.busy ||
        _controller.status == null && _controller.failure == null) {
      return [
        Semantics(
          key: const ValueKey('server-media-flow-loading'),
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
    final status = _controller.status!;
    return [
      Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(_status(l, status.state), style: AppText.title2),
        ),
      ),
      for (final stage in status.stages) _stage(l, stage),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Semantics(
          key: const ValueKey('server-media-flow-refresh'),
          button: true,
          label: l.commonRefresh,
          child: ExcludeSemantics(
            child: CupertinoButton.filled(
              minimumSize: const Size(48, 48),
              onPressed: _active && !_controller.busy ? _load : null,
              child: Text(l.commonRefresh),
            ),
          ),
        ),
      ),
    ];
  }

  void _prepare() {
    final page = widget.catalogPage;
    final item = widget.catalogItem;
    final playback = _playback;
    final current = _capture();
    if (page == null || item == null || playback == null || !current()) return;
    unawaited(playback.prepare(page, item, current: current));
  }

  Future<void> _confirm(
    AppLocalizations l,
    ServerMediaPlaybackTarget target,
  ) async {
    final playback = _playback;
    final current = _capture();
    if (playback == null || !current()) return;
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l.serverMediaPlaybackConfirmTitle),
        content: Text(l.serverMediaPlaybackConfirmBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.commonCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('server-media-playback-confirm'),
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.serverMediaPlaybackConfirm),
          ),
        ],
      ),
    );
    if (accepted == true && current()) {
      await playback.play(target, current: current);
    }
  }

  List<Widget> _playbackBody(AppLocalizations l) {
    final playback = _playback;
    if (playback == null) return const [];
    final intent = playback.intent;
    final receipt = playback.receipt;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
        child: Text(l.serverMediaPlaybackTitle, style: AppText.title2),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Text(l.serverMediaPlaybackBody, style: AppText.body),
      ),
      if (playback.busy)
        Semantics(
          liveRegion: true,
          child: const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CupertinoActivityIndicator()),
          ),
        )
      else if (receipt != null)
        Semantics(
          key: ValueKey(
            receipt.state == ServerMediaPlaybackReceiptState.succeeded
                ? 'server-media-playback-succeeded'
                : 'server-media-playback-needs-attention',
          ),
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
            child: Text(
              receipt.state == ServerMediaPlaybackReceiptState.succeeded
                  ? l.serverMediaPlaybackAccepted
                  : l.serverMediaPlaybackUnknown,
              style: AppText.body,
            ),
          ),
        )
      else if (playback.failure != null)
        Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
            child: Text(l.commonError, style: AppText.body),
          ),
        )
      else if (intent == null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
          child: Semantics(
            key: const ValueKey('server-media-playback-prepare'),
            button: true,
            label: l.serverMediaPlaybackPrepare,
            child: ExcludeSemantics(
              child: CupertinoButton.filled(
                minimumSize: const Size(48, 48),
                onPressed: _active ? _prepare : null,
                child: Text(l.serverMediaPlaybackPrepare),
              ),
            ),
          ),
        )
      else
        for (final target in intent.targets.where((item) => item.available))
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 80),
            child: Semantics(
              key: ValueKey('server-media-playback-target-${target.id}'),
              button: true,
              label: l.serverMediaPlaybackTarget(target.name),
              child: ExcludeSemantics(
                child: CupertinoButton(
                  minimumSize: const Size(48, 48),
                  onPressed: _active ? () => _confirm(l, target) : null,
                  child: Text(target.name),
                ),
              ),
            ),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_controller, ?_playback]),
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      return ServiceRootScaffold(
        title: widget.title,
        slivers: [
          SliverToBoxAdapter(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [..._body(l), ..._playbackBody(l)],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
