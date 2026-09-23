import 'package:flutter/foundation.dart';

import '../domain/media_archive_health.dart';

final Object _unavailableAuthorityRevision = Object();

Object? _captureAuthorityRevision(Object Function()? read) {
  if (read == null) return null;
  try {
    return read();
  } catch (_) {
    return _unavailableAuthorityRevision;
  }
}

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
       _knownAuthorityRevision = _captureAuthorityRevision(authorityRevision) {
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

  bool _authorized() {
    try {
      return authorized();
    } catch (_) {
      return false;
    }
  }

  Object? _revision() => _captureAuthorityRevision(_authorityRevision);

  bool _sameAuthority(Object? revision) {
    final current = _revision();
    return !identical(revision, _unavailableAuthorityRevision) &&
        !identical(current, _unavailableAuthorityRevision) &&
        current == revision &&
        _authorized();
  }

  bool _operationCurrent(int operation, Object? revision) =>
      !_disposed && operation == _epoch && _sameAuthority(revision);

  void _retireOperation(int operation) {
    if (_disposed || operation != _epoch) return;
    _epoch++;
    _knownAuthorityRevision = _revision();
    snapshot = null;
    state = MediaArchiveCardState.idle;
    notifyListeners();
  }

  void _authorityChanged() {
    final revision = _revision();
    if (!_authorized() ||
        identical(revision, _unavailableAuthorityRevision) ||
        revision != _knownAuthorityRevision) {
      retire();
    }
  }

  void retire() {
    if (_disposed) return;
    _epoch++;
    _knownAuthorityRevision = _revision();
    snapshot = null;
    state = MediaArchiveCardState.idle;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (!canRefresh) return;
    final revision = _revision();
    if (!_authorized() || identical(revision, _unavailableAuthorityRevision)) {
      snapshot = null;
      state = MediaArchiveCardState.denied;
      notifyListeners();
      return;
    }
    _knownAuthorityRevision = revision;
    final operation = ++_epoch;
    snapshot = null;
    state = MediaArchiveCardState.loading;
    notifyListeners();
    try {
      final value = await read();
      if (!_operationCurrent(operation, revision)) {
        _retireOperation(operation);
        return;
      }
      snapshot = value;
      state = switch (value.state) {
        MediaArchiveSnapshotState.healthy => MediaArchiveCardState.healthy,
        MediaArchiveSnapshotState.attention => MediaArchiveCardState.attention,
        MediaArchiveSnapshotState.incomplete => MediaArchiveCardState.partial,
      };
    } on MediaArchiveReadException catch (error) {
      if (!_operationCurrent(operation, revision)) {
        _retireOperation(operation);
        return;
      }
      state = switch (error.kind) {
        'media_archive_snapshot_stale' => MediaArchiveCardState.stale,
        'connection_failed' => MediaArchiveCardState.offline,
        'forbidden' => MediaArchiveCardState.denied,
        _ => MediaArchiveCardState.unsupported,
      };
    } catch (_) {
      if (!_operationCurrent(operation, revision)) {
        _retireOperation(operation);
        return;
      }
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
