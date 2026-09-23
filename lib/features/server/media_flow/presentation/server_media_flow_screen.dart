import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_media_flow_controller.dart';
import '../domain/server_media_flow_models.dart';

/// Read-only, lifecycle-bound evidence for one central Core media flow.
final class ServerMediaFlowScreen extends ConsumerStatefulWidget {
  const ServerMediaFlowScreen({
    super.key,
    required this.mediaKey,
    required this.title,
    this.requestId,
  });

  final String mediaKey, title;

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
      _account.session?.user.canAdminister == true &&
      (ModalRoute.of(context)?.isCurrent ?? true);

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
    _controller.retire();
  }

  bool Function() _capture() {
    final lifecycle = _lifecycle;
    return () => _active && lifecycle == _lifecycle;
  }

  void _load() {
    final current = _capture();
    if (!current() || _controller.busy) return;
    unawaited(_controller.load(widget.mediaKey, current: current));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _controller.dispose();
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
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
                    children: _body(l),
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
