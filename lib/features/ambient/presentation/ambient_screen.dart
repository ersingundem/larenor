import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../shared/theme/typography.dart';
import '../../auth/providers/auth_providers.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../../wellbeing/providers/wellbeing_privacy_providers.dart';
import '../data/ambient_repository.dart';
import '../domain/ambient_settings.dart';
import '../providers/ambient_providers.dart';

class AmbientScreen extends ConsumerStatefulWidget {
  const AmbientScreen({super.key});
  @override
  ConsumerState<AmbientScreen> createState() => _AmbientScreenState();
}

class _AmbientScreenState extends ConsumerState<AmbientScreen>
    with WidgetsBindingObserver {
  DateTime _now = DateTime.now();
  Timer? _minute;
  bool _foreground = true;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _scheduleMinute();
  }

  void _scheduleMinute() {
    _minute?.cancel();
    if (!_foreground || !_visible) return;
    final now = DateTime.now();
    final next = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute + 1,
    );
    _minute = Timer(next.difference(now), () {
      if (!mounted || !_foreground || !_visible) return;
      setState(() => _now = DateTime.now());
      _scheduleMinute();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible =
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent != false;
    if (_visible != visible) {
      _visible = visible;
      _scheduleMinute();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _scheduleMinute();
    if (mounted) setState(() => _now = DateTime.now());
  }

  @override
  void dispose() {
    _minute?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settingsReading = ref.watch(ambientSettingsProvider);
    final settings = settingsReading.isLoading || settingsReading.hasError
        ? const AmbientSettings()
        : settingsReading.value ?? const AmbientSettings();
    final library = settings.photosEnabled && _foreground && _visible
        ? ref.watch(ambientLibraryProvider)
        : const AsyncData<List<String>>([]);
    final photos = library.isLoading || library.hasError
        ? const <String>[]
        : library.value ?? const <String>[];
    final config = ref.watch(connectionConfigProvider);
    final reading = ref.watch(publicHaEntitiesProvider);
    final entities =
        config.isLoading ||
            config.hasError ||
            config.value == null ||
            reading.isLoading ||
            reading.hasError
        ? null
        : reading.value;
    HaEntity? weather;
    if (settings.showWeather && entities != null) {
      for (final entity in entities.values) {
        final value = entity.attributes['temperature'];
        if (entity.domain == 'weather' &&
            !{'unknown', 'unavailable'}.contains(entity.state) &&
            value is num &&
            value.isFinite) {
          weather = entity;
          break;
        }
      }
    }
    final showClock = settings.showClock || photos.isEmpty;
    final time =
        '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';
    final date = DateFormat.MMMMEEEEd(
      Localizations.localeOf(context).toString(),
    ).format(_now);
    final shift =
        settings.pixelShift && !MediaQuery.disableAnimationsOf(context)
        ? <Offset>[
            const Offset(-8, -8),
            const Offset(0, -8),
            const Offset(8, -8),
            const Offset(8, 0),
            const Offset(8, 8),
            const Offset(0, 8),
            const Offset(-8, 8),
            const Offset(-8, 0),
          ][(_now.millisecondsSinceEpoch ~/ 60000) % 8]
        : Offset.zero;

    return ColoredBox(
      color: CupertinoColors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (photos.isNotEmpty)
            AmbientPhotoSequence(
              repository: ref.watch(ambientRepositoryProvider),
              ids: photos,
              interval: Duration(seconds: settings.intervalSeconds),
              fit: settings.fit,
              active: _foreground && _visible,
              placeholder: showClock
                  ? const SizedBox.expand()
                  : SafeArea(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Transform.translate(
                            offset: shift,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Column(
                                key: const ValueKey('ambient-photo-fallback'),
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    time,
                                    style: AppText.ambientClock.copyWith(
                                      color: CupertinoColors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    date,
                                    style: AppText.title3.copyWith(
                                      color: CupertinoColors.systemGrey2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          if (showClock || weather != null)
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Transform.translate(
                        key: const ValueKey('ambient-clock-shift'),
                        offset: shift,
                        child: Column(
                          mainAxisAlignment: photos.isEmpty
                              ? MainAxisAlignment.center
                              : MainAxisAlignment.end,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: photos.isEmpty
                                  ? null
                                  : BoxDecoration(
                                      color: CupertinoColors.black.withValues(
                                        alpha: 0.78,
                                      ),
                                      borderRadius: BorderRadius.circular(24),
                                    ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (showClock) ...[
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        time,
                                        style: AppText.ambientClock.copyWith(
                                          color: CupertinoColors.white,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      date,
                                      textAlign: TextAlign.center,
                                      style: AppText.title3.copyWith(
                                        color: CupertinoColors.systemGrey2,
                                      ),
                                    ),
                                  ],
                                  if (weather != null) ...[
                                    const SizedBox(height: 16),
                                    Text(
                                      '${weather.attributes['temperature']}° · ${weather.state}',
                                      textAlign: TextAlign.center,
                                      style: AppText.callout.copyWith(
                                        color: CupertinoColors.systemGrey2,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One decoded image at a time; never preloads the whole album. Corrupt entries
/// are tried once per cycle and an all-broken library stops without retry loops.
class AmbientPhotoSequence extends StatefulWidget {
  const AmbientPhotoSequence({
    super.key,
    required this.repository,
    required this.ids,
    required this.interval,
    required this.fit,
    required this.active,
    this.placeholder = const SizedBox.expand(),
  });
  final AmbientRepository repository;
  final List<String> ids;
  final Duration interval;
  final AmbientPhotoFit fit;
  final bool active;
  final Widget placeholder;

  @override
  State<AmbientPhotoSequence> createState() => _AmbientPhotoSequenceState();
}

class _AmbientPhotoSequenceState extends State<AmbientPhotoSequence> {
  Timer? _next;
  Uint8List? _bytes;
  int _index = 0, _generation = 0;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void didUpdateWidget(AmbientPhotoSequence oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active ||
        oldWidget.ids.join() != widget.ids.join() ||
        !identical(oldWidget.repository, widget.repository)) {
      _restart();
    } else if (oldWidget.interval != widget.interval) {
      _schedule();
    }
  }

  void _restart() {
    _generation++;
    _next?.cancel();
    _releaseImage();
    _index = 0;
    if (widget.active && widget.ids.isNotEmpty) unawaited(_load(_generation));
  }

  Future<void> _load(int generation) async {
    final ids = List<String>.of(widget.ids);
    final repository = widget.repository;
    for (var attempt = 0; attempt < ids.length; attempt++) {
      if (!mounted || generation != _generation || !widget.active) return;
      try {
        final bytes = await repository
            .readPhoto(ids[_index])
            .timeout(const Duration(seconds: 15));
        if (!mounted || generation != _generation || !widget.active) return;
        _releaseImage();
        setState(() => _bytes = bytes);
        _schedule();
        return;
      } catch (_) {
        if (!mounted || generation != _generation || !widget.active) return;
        _index = (_index + 1) % ids.length;
      }
    }
    if (mounted && generation == _generation) setState(_releaseImage);
  }

  void _schedule() {
    _next?.cancel();
    if (!widget.active || widget.ids.length < 2 || _bytes == null) return;
    _next = Timer(widget.interval, () {
      if (!mounted || !widget.active) return;
      _index = (_index + 1) % widget.ids.length;
      unawaited(_load(_generation));
    });
  }

  void _releaseImage() {
    final previous = _bytes;
    _bytes = null;
    if (previous != null) unawaited(MemoryImage(previous).evict());
  }

  @override
  void dispose() {
    _generation++;
    _next?.cancel();
    _releaseImage();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _bytes == null
      ? widget.placeholder
      : Image.memory(
          _bytes!,
          key: ValueKey(widget.ids[_index]),
          fit: widget.fit == AmbientPhotoFit.contain
              ? BoxFit.contain
              : BoxFit.cover,
          gaplessPlayback: false,
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) => widget.placeholder,
        );
}
