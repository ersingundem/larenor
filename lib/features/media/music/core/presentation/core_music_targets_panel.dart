import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../../../../shared/theme/typography.dart';
import '../../../../server/providers/server_providers.dart';
import '../data/core_music_targets_api.dart';
import '../data/core_music_targets_controller.dart';
import '../domain/core_music_target_models.dart';

class CoreMusicTargetsPanel extends ConsumerStatefulWidget {
  const CoreMusicTargetsPanel({super.key, this.controller});

  final CoreMusicTargetsController? controller;

  @override
  ConsumerState<CoreMusicTargetsPanel> createState() =>
      _CoreMusicTargetsPanelState();
}

class _CoreMusicTargetsPanelState extends ConsumerState<CoreMusicTargetsPanel> {
  late final CoreMusicTargetsController _controller;
  late final bool _ownsController;
  ValueListenable<TickerModeData>? _ticker;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    if (widget.controller case final controller?) {
      _controller = controller;
    } else {
      final account = ref.read(serverAccountControllerProvider);
      final api = AccountCoreMusicTargetsApi(account);
      _controller = CoreMusicTargetsController(
        api: api,
        lifecycle: account,
        authorized: () => api.authorized,
      );
    }
    _controller.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticker = TickerMode.getValuesNotifier(context);
    if (!identical(ticker, _ticker)) {
      _ticker?.removeListener(_visibilityChanged);
      _ticker = ticker;
      ticker.addListener(_visibilityChanged);
    }
    _updateVisibility();
  }

  void _visibilityChanged() => _updateVisibility();

  void _updateVisibility() {
    final value =
        (_ticker?.value.enabled ?? true) &&
        (ModalRoute.isCurrentOf(context) ?? true);
    if (value == _visible && _controller.loaded) return;
    _visible = value;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.setVisible(value);
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker?.removeListener(_visibilityChanged);
    _controller.removeListener(_changed);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      container: true,
      label: l10n.coreMusicOutputsTitle,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
            context,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(l10n.coreMusicOutputsTitle, style: AppText.title2),
                CupertinoButton(
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  onPressed: _controller.busy || !_controller.isAuthorized
                      ? null
                      : _controller.refresh,
                  child: _controller.busy
                      ? const CupertinoActivityIndicator()
                      : Text(l10n.commonRefresh),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(l10n.coreMusicOutputsHint, style: AppText.footnote),
            const SizedBox(height: 12),
            if (!_controller.isAuthorized)
              _StatusMessage(l10n.coreMusicNotReady)
            else if (_controller.busy && !_controller.loaded)
              const Center(child: CupertinoActivityIndicator())
            else if (_controller.failure != null)
              _StatusMessage(_failureLabel(l10n, _controller.failure!))
            else if (_controller.inventory?.targets.isEmpty ?? true)
              _StatusMessage(l10n.coreMusicNoTargets)
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final scale = MediaQuery.textScalerOf(context).scale(1);
                  final columns = constraints.maxWidth >= 760 && scale < 1.8
                      ? 2
                      : 1;
                  final width = columns == 2
                      ? (constraints.maxWidth - 12) / 2
                      : constraints.maxWidth;
                  return FocusTraversalGroup(
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final (index, target)
                            in _controller.inventory!.targets.indexed)
                          SizedBox(
                            width: width,
                            child: _TargetButton(
                              target: target,
                              selected:
                                  _controller.selectedTargetId == target.id,
                              autofocus: index == 0,
                              onPressed: () => _controller.select(target.id),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  String _failureLabel(AppLocalizations l10n, String failure) =>
      switch (failure) {
        'forbidden' ||
        'unauthorized' ||
        'password_change_required' => l10n.coreMusicNotReady,
        'not_ready' ||
        'ambiguous_installation' ||
        'stale' ||
        'invalid_response' => l10n.musicStale,
        _ => l10n.healthReadError,
      };
}

class _StatusMessage extends StatelessWidget {
  const _StatusMessage(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Semantics(liveRegion: true, child: Text(text, style: AppText.body));
}

class _TargetButton extends StatelessWidget {
  const _TargetButton({
    required this.target,
    required this.selected,
    required this.autofocus,
    required this.onPressed,
  });

  final CoreMusicTarget target;
  final bool selected;
  final bool autofocus;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final kind = _kindLabel(l10n);
    final state = switch (target.playbackState) {
      'playing' => l10n.entityStatePlaying,
      'paused' => l10n.entityStatePaused,
      _ => l10n.entityStateIdle,
    };
    final nowPlaying = target.queue?.nowPlaying;
    final enabled = target.available && target.enabled;
    final label = [
      target.name,
      kind,
      state,
      if (nowPlaying != null) nowPlaying.title,
    ].join(', ');
    final background = CupertinoColors.tertiarySystemGroupedBackground
        .resolveFrom(context);
    final border = selected
        ? CupertinoColors.activeBlue.resolveFrom(context)
        : CupertinoColors.separator.resolveFrom(context);
    return Semantics(
      key: ValueKey('core-music-target-${target.id}'),
      label: label,
      button: true,
      selected: selected,
      enabled: enabled,
      excludeSemantics: true,
      child: Focus(
        autofocus: autofocus,
        onKeyEvent: (node, event) {
          if (enabled &&
              event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space)) {
            onPressed();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: CupertinoButton(
          minimumSize: const Size(48, 48),
          padding: EdgeInsets.zero,
          onPressed: enabled ? onPressed : null,
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 96),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: border, width: selected ? 2 : 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Icon(_icon, size: 22),
                    Text(target.name, style: AppText.headline),
                    Text(kind, style: AppText.footnote),
                  ],
                ),
                const SizedBox(height: 8),
                Text(state, style: AppText.subhead),
                if (nowPlaying != null) ...[
                  const SizedBox(height: 4),
                  Text(nowPlaying.title, style: AppText.body),
                  const SizedBox(height: 2),
                  Text(
                    l10n.coreMusicQueueSummary(
                      target.queue!.itemCount,
                      _duration(nowPlaying.positionSeconds),
                      _duration(nowPlaying.durationSeconds),
                    ),
                    style: AppText.footnote,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData get _icon => switch (target.transport) {
    CoreMusicTransport.airplay => CupertinoIcons.speaker_2,
    CoreMusicTransport.chromecast => CupertinoIcons.tv,
  };

  String _kindLabel(AppLocalizations l10n) {
    if (target.homePod) return l10n.coreMusicHomePod;
    if (target.kind == CoreMusicTargetKind.group) return l10n.coreMusicGroup;
    return switch (target.transport) {
      CoreMusicTransport.airplay => l10n.coreMusicAirPlay,
      CoreMusicTransport.chromecast => l10n.coreMusicChromecast,
    };
  }

  static String _duration(int? seconds) {
    if (seconds == null) return '--:--';
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return '$minutes:${remainder.toString().padLeft(2, '0')}';
  }
}
