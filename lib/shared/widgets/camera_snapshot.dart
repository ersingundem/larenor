import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../features/ha_client/providers/ha_client_providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../utils/foreground_poller.dart';

/// Polls `/api/camera_proxy/<entity_id>` for a JPEG snapshot on an interval.
/// Not a live MJPEG/HLS stream — that's a heavier lift deferred to a later
/// pass; periodic snapshots are the pragmatic v1 for both the dashboard
/// camera tile and the admin Cameras screen.
class CameraSnapshot extends ConsumerStatefulWidget {
  const CameraSnapshot({
    super.key,
    required this.entityId,
    this.refreshInterval = const Duration(seconds: 5),
    this.fit = BoxFit.cover,
  });

  final String entityId;
  final Duration refreshInterval;
  final BoxFit fit;

  @override
  ConsumerState<CameraSnapshot> createState() => _CameraSnapshotState();
}

class _CameraSnapshotState extends ConsumerState<CameraSnapshot>
    with WidgetsBindingObserver {
  ui.Image? _frame;
  DateTime? _receivedAt;
  bool _stale = false;
  late final ForegroundPoller _poller;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _poller = ForegroundPoller(interval: widget.refreshInterval, poll: _fetch);
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(haRestClientProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      setState(() {
        _replaceFrame(null);
        _receivedAt = null;
        _stale = false;
      });
      _poller.refresh();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Stateful tab branches remain mounted. Hidden camera pages should not
    // continue network polling or accept a frame from their previous visit.
    if (TickerMode.valuesOf(context).enabled) {
      _poller.start();
    } else {
      _generation++;
      _stale = _frame != null;
      _poller.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _generation++;
      if (mounted) setState(() => _stale = _frame != null);
    }
  }

  Future<void> _fetch() async {
    final rest = ref.read(haRestClientProvider);
    if (rest == null) {
      if (mounted) setState(() => _stale = true);
      return;
    }
    final generation = _generation;
    try {
      final bytes = await rest.getCameraImage(widget.entityId);
      if (!mounted || !_poller.isActive || generation != _generation) return;
      if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
        throw const FormatException('Invalid camera frame size.');
      }
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 1600,
        allowUpscaling: false,
      );
      final ui.Image image;
      try {
        image = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
      if (mounted && _poller.isActive && generation == _generation) {
        setState(() {
          _replaceFrame(image);
          _receivedAt = DateTime.now();
          _stale = false;
        });
      } else {
        image.dispose();
      }
    } catch (_) {
      if (mounted && _poller.isActive && generation == _generation) {
        setState(() => _stale = true);
      }
    }
  }

  @override
  void didUpdateWidget(covariant CameraSnapshot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _poller.interval = widget.refreshInterval;
    if (oldWidget.entityId != widget.entityId) {
      _generation++;
      _replaceFrame(null);
      _receivedAt = null;
      _stale = false;
      _poller.refresh();
    }
  }

  @override
  void dispose() {
    _poller.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _frame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ColoredBox(
      color: CupertinoColors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_frame != null)
            RawImage(
              image: _frame,
              fit: widget.fit,
              width: double.infinity,
              height: double.infinity,
            )
          else if (!_stale)
            const Center(
              child: CupertinoActivityIndicator(color: CupertinoColors.white),
            ),
          if (_stale || _receivedAt != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                color: CupertinoColors.black.withValues(alpha: 0.72),
                padding: const EdgeInsets.all(8),
                child: Text(
                  [
                    if (_stale) l10n.cameraUnavailable,
                    if (_receivedAt != null)
                      l10n.cameraSnapshotTime(
                        DateFormat.Hms(l10n.localeName)
                            .format(_receivedAt!.toLocal()),
                      ),
                  ].join('\n'),
                  style: const TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _replaceFrame(ui.Image? image) {
    final old = _frame;
    _frame = image;
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }
}
