import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/ha_client/providers/ha_client_providers.dart';
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

class _CameraSnapshotState extends ConsumerState<CameraSnapshot> {
  Uint8List? _bytes;
  late final ForegroundPoller _poller;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _poller = ForegroundPoller(interval: widget.refreshInterval, poll: _fetch);
    ref.listenManual(haRestClientProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      setState(() => _bytes = null);
      _poller.refresh();
    });
    _poller.start();
  }

  Future<void> _fetch() async {
    final rest = ref.read(haRestClientProvider);
    if (rest == null) return;
    final generation = _generation;
    try {
      final bytes = await rest.getBytes('/api/camera_proxy/${widget.entityId}');
      if (mounted && _poller.isActive && generation == _generation) {
        setState(() => _bytes = bytes);
      }
    } catch (_) {
      // Keep showing the last good frame on a transient failure.
    }
  }

  @override
  void didUpdateWidget(covariant CameraSnapshot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _poller.interval = widget.refreshInterval;
    if (oldWidget.entityId != widget.entityId) {
      _generation++;
      _bytes = null;
      _poller.refresh();
    }
  }

  @override
  void dispose() {
    _poller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: CupertinoColors.black,
      child: _bytes == null
          ? const Center(
              child: CupertinoActivityIndicator(color: CupertinoColors.white),
            )
          : Image.memory(
              _bytes!,
              fit: widget.fit,
              gaplessPlayback: true,
              width: double.infinity,
              height: double.infinity,
            ),
    );
  }
}
