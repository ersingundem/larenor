import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../data/local_audio_bridge.dart';
import '../domain/local_audio_models.dart';
import '../providers/local_audio_providers.dart';
import 'playback_power_screen.dart';

String localAudioFailureLabel(AppLocalizations l10n, Object? error) {
  final failure = error is LocalAudioException ? error.failure : error;
  return switch (failure) {
    LocalAudioFailure.unsupported => l10n.localAudioUnsupported,
    LocalAudioFailure.invalidSource => l10n.localAudioInvalidSource,
    LocalAudioFailure.foregroundRequired => l10n.localAudioForeground,
    LocalAudioFailure.network => l10n.localAudioNetworkError,
    LocalAudioFailure.unsupportedFormat => l10n.localAudioFormatError,
    _ => l10n.localAudioUnavailable,
  };
}

class LocalAudioScreen extends ConsumerStatefulWidget {
  const LocalAudioScreen({super.key});
  @override
  ConsumerState<LocalAudioScreen> createState() => _LocalAudioScreenState();
}

class _LocalAudioScreenState extends ConsumerState<LocalAudioScreen>
    with WidgetsBindingObserver {
  final _title = TextEditingController();
  final _address = TextEditingController();
  String _mime = 'audio/mpeg';
  String? _error;
  bool _foreground = true;
  bool _busy = false;
  int _generation = 0;
  double? _seekSeconds;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      _foreground = state == AppLifecycleState.resumed;
      _generation++;
      _seekSeconds = null;
    });
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _title.dispose();
    _address.dispose();
    // Native playback owns its service and survives this route's disposal.
    super.dispose();
  }

  bool get _canAct =>
      mounted &&
      _foreground &&
      AppInteractionScope.maybeRead(context)?.active != false &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true;

  Future<void> _run(
    Future<void> Function(LocalAudioBridge) action, {
    String? expectedSourceId,
  }) async {
    if (!_canAct || _busy) return;
    final generation = _generation;
    final interaction = AppInteractionScope.maybeRead(context);
    final epoch = interaction?.epoch;
    bool current() =>
        _canAct &&
        generation == _generation &&
        identical(interaction, AppInteractionScope.maybeRead(context)) &&
        interaction?.epoch == epoch;
    final bridge = ref.read(localAudioBridgeProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (expectedSourceId != null) {
        final latest = await bridge.snapshot();
        if (!current()) return;
        if (latest.sourceId != expectedSourceId) {
          throw const LocalAudioException(LocalAudioFailure.unavailable);
        }
      }
      await action(bridge);
    } catch (error) {
      if (current()) {
        setState(
          () => _error = localAudioFailureLabel(
            AppLocalizations.of(context),
            error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _seekSeconds = null;
        });
      }
    }
  }

  void _play() {
    if (!_canAct || _busy) return;
    try {
      final text = _address.text.trim();
      // Check raw authority before Uri can normalize an empty user-info part.
      final authority = RegExp(r'^https?://([^/?#]*)')
          .firstMatch(text)
          ?.group(1);
      if (authority == null ||
          authority.contains('@') ||
          text.contains(RegExp(r'[\x00-\x20\x7f\\]'))) {
        throw const LocalAudioException(LocalAudioFailure.invalidSource);
      }
      final source = LocalAudioSource(
        id: 'audio_${DateTime.now().microsecondsSinceEpoch}',
        uri: Uri.parse(text),
        mimeType: _mime,
        title: _title.text.trim(),
      );
      _run((bridge) => bridge.play(source));
    } catch (_) {
      setState(
        () => _error = AppLocalizations.of(context).localAudioInvalidSource,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final active = _foreground && TickerMode.valuesOf(context).enabled;
    final reading = active ? ref.watch(localAudioProvider) : null;
    final state = reading == null || reading.isLoading || reading.hasError
        ? null
        : reading.value;
    final ready = active && !_busy && state?.supported == true;
    final duration = state?.duration?.inMilliseconds.toDouble();
    final position = state?.position?.inMilliseconds.toDouble();
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.localAudioTitle)),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Icon(CupertinoIcons.music_note_2, size: 44),
                const SizedBox(height: 16),
                Text(l10n.localAudioHint, style: AppText.body),
                const SizedBox(height: 20),
                if (reading?.isLoading == true)
                  const CupertinoActivityIndicator(),
                if (reading?.hasError == true) Text(l10n.localAudioUnavailable),
                if (state?.supported == false) Text(l10n.localAudioUnsupported),
                if (_error != null) Text(_error!),
                if (state?.failure != null)
                  Text(localAudioFailureLabel(l10n, state!.failure)),
                if (state?.supported == true)
                  _AudioPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          state!.title ?? l10n.localAudioIdle,
                          style: AppText.title2,
                        ),
                        if (state.artist != null)
                          Text(state.artist!, style: AppText.body),
                        if (state.album != null)
                          Text(state.album!, style: AppText.subhead),
                        const SizedBox(height: 12),
                        Text(switch (state.phase) {
                          LocalAudioPhase.idle => l10n.localAudioIdle,
                          LocalAudioPhase.loading => l10n.localAudioLoading,
                          LocalAudioPhase.ready =>
                            state.isPlaying
                                ? l10n.localAudioPlaying
                                : l10n.localAudioPaused,
                          LocalAudioPhase.ended => l10n.localAudioEnded,
                          LocalAudioPhase.error => l10n.localAudioUnavailable,
                        }),
                        if (duration != null &&
                            duration > 0 &&
                            position != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            '${_time(Duration(milliseconds: position.round()))} / ${_time(state.duration!)}',
                            style: AppText.footnote,
                          ),
                          Semantics(
                            label: l10n.localAudioPosition,
                            child: SizedBox(
                              width: double.infinity,
                              child: CupertinoSlider(
                                value: (_seekSeconds ?? position).clamp(
                                  0,
                                  duration,
                                ),
                                min: 0,
                                max: duration,
                                onChanged: ready && state.canSeek
                                    ? (value) =>
                                          setState(() => _seekSeconds = value)
                                    : null,
                                onChangeEnd: ready && state.canSeek
                                    ? (value) => _run(
                                        (bridge) => bridge.seek(
                                          Duration(milliseconds: value.round()),
                                          expectedSourceId: state.sourceId,
                                        ),
                                        expectedSourceId: state.sourceId,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ],
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            if (state.canPause)
                              CupertinoButton(
                                onPressed: ready
                                    ? () => _run(
                                        (bridge) => bridge.pause(
                                          expectedSourceId: state.sourceId,
                                        ),
                                        expectedSourceId: state.sourceId,
                                      )
                                    : null,
                                child: Text(l10n.localAudioPause),
                              ),
                            if (state.canPlay && !state.isPlaying)
                              CupertinoButton(
                                onPressed: ready
                                    ? () => _run(
                                        (bridge) => bridge.resume(
                                          expectedSourceId: state.sourceId,
                                        ),
                                        expectedSourceId: state.sourceId,
                                      )
                                    : null,
                                child: Text(l10n.localAudioResume),
                              ),
                            if (state.canStop)
                              CupertinoButton(
                                onPressed: ready
                                    ? () => _run(
                                        (bridge) => bridge.stop(
                                          expectedSourceId: state.sourceId,
                                        ),
                                        expectedSourceId: state.sourceId,
                                      )
                                    : null,
                                child: Text(l10n.localAudioStop),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 20),
                _AudioPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.localAudioSourceTitle, style: AppText.title2),
                      const SizedBox(height: 16),
                      CupertinoTextField(
                        key: const ValueKey('local-audio-name'),
                        controller: _title,
                        enabled: ready,
                        maxLength: 256,
                        placeholder: l10n.localAudioName,
                        padding: const EdgeInsets.all(14),
                      ),
                      const SizedBox(height: 12),
                      CupertinoTextField(
                        key: const ValueKey('local-audio-url'),
                        controller: _address,
                        enabled: ready,
                        maxLength: 2048,
                        autocorrect: false,
                        enableSuggestions: false,
                        keyboardType: TextInputType.url,
                        placeholder: l10n.localAudioAddress,
                        padding: const EdgeInsets.all(14),
                      ),
                      const SizedBox(height: 12),
                      Text(l10n.localAudioFormat, style: AppText.headline),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final entry in const {
                            'audio/mpeg': 'MP3',
                            'audio/aac': 'AAC',
                            'audio/mp4': 'M4A',
                            'audio/ogg': 'OGG',
                            'audio/flac': 'FLAC',
                            'audio/wav': 'WAV',
                          }.entries)
                            CupertinoButton(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              color: _mime == entry.key
                                  ? CupertinoColors.activeBlue
                                  : null,
                              foregroundColor: _mime == entry.key
                                  ? CupertinoColors.white
                                  : null,
                              onPressed: ready
                                  ? () => setState(() => _mime = entry.key)
                                  : null,
                              child: Text(entry.value),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(l10n.localAudioSourceHint, style: AppText.footnote),
                      const SizedBox(height: 16),
                      CupertinoButton.filled(
                        key: const ValueKey('local-audio-start'),
                        onPressed: ready ? _play : null,
                        child: _busy
                            ? const CupertinoActivityIndicator()
                            : Text(l10n.localAudioTitle),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                CupertinoButton(
                  onPressed: !active || _busy
                      ? null
                      : () => Navigator.of(context).push(
                          CupertinoPageRoute<void>(
                            builder: (_) => const PlaybackPowerScreen(),
                          ),
                        ),
                  child: Text(l10n.localAudioPowerTitle),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _time(Duration value) {
  final seconds = value.inSeconds;
  final minutes = seconds ~/ 60;
  return '${minutes.toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class _AudioPanel extends StatelessWidget {
  const _AudioPanel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
    ),
    child: child,
  );
}
