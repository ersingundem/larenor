import 'package:flutter/foundation.dart';

import '../domain/media_archive_health.dart';

enum MediaArchiveCardState {
  idle,
  loading,
  healthy,
  attention,
  partial,
  stale,
  offline,
  denied,
  unsupported,
}

/// One visible card owns one explicit read. It never polls or retries.
final class MediaArchiveHealthController extends ChangeNotifier {
  MediaArchiveHealthController({
    required this.read,
    required this.authorized,
    Listenable? authority,
    Object Function()? authorityRevision,
  }) : _authority = authority,
       _authorityRevision = authorityRevision,
       _knownAuthorityRevision = authorityRevision?.call() {
    authority?.addListener(_authorityChanged);
  }

  final Future<MediaArchiveHealthSnapshot> Function() read;
  final bool Function() authorized;
  final Listenable? _authority;
  final Object Function()? _authorityRevision;
  Object? _knownAuthorityRevision;
  int _epoch = 0;
  bool _disposed = false;
  MediaArchiveCardState state = MediaArchiveCardState.idle;
  MediaArchiveHealthSnapshot? snapshot;

  bool get canRefresh => !_disposed && state != MediaArchiveCardState.loading;

  void _authorityChanged() {
    final revision = _authorityRevision?.call();
    if (!authorized() || revision != _knownAuthorityRevision) retire();
  }

  void retire() {
    if (_disposed) return;
    _epoch++;
    _knownAuthorityRevision = _authorityRevision?.call();
    snapshot = null;
    state = MediaArchiveCardState.idle;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (!canRefresh) return;
    if (!authorized()) {
      snapshot = null;
      state = MediaArchiveCardState.denied;
      notifyListeners();
      return;
    }
    final operation = ++_epoch;
    snapshot = null;
    state = MediaArchiveCardState.loading;
    notifyListeners();
    try {
      final value = await read();
      if (_disposed || operation != _epoch || !authorized()) return;
      snapshot = value;
      state = switch (value.state) {
        MediaArchiveSnapshotState.healthy => MediaArchiveCardState.healthy,
        MediaArchiveSnapshotState.attention => MediaArchiveCardState.attention,
        MediaArchiveSnapshotState.incomplete => MediaArchiveCardState.partial,
      };
    } on MediaArchiveReadException catch (error) {
      if (_disposed || operation != _epoch || !authorized()) return;
      state = switch (error.kind) {
        'media_archive_snapshot_stale' => MediaArchiveCardState.stale,
        'connection_failed' => MediaArchiveCardState.offline,
        'forbidden' => MediaArchiveCardState.denied,
        _ => MediaArchiveCardState.unsupported,
      };
    } catch (_) {
      if (_disposed || operation != _epoch || !authorized()) return;
      state = MediaArchiveCardState.offline;
    }
    if (!_disposed && operation == _epoch) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _authority?.removeListener(_authorityChanged);
    super.dispose();
  }
}
