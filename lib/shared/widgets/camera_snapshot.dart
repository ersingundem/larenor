import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/ha_client/providers/ha_client_providers.dart';

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
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _fetch();
    _timer = Timer.periodic(widget.refreshInterval, (_) => _fetch());
  }

  Future<void> _fetch() async {
    final rest = ref.read(haRestClientProvider);
    if (rest == null) return;
    try {
      final bytes = await rest.getBytes('/api/camera_proxy/${widget.entityId}');
      if (mounted) setState(() => _bytes = bytes);
    } catch (_) {
      // Keep showing the last good frame on a transient failure.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
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
