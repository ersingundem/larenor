import '../../../core/configuration_writes.dart';
import '../../dashboard/data/dashboard_repository.dart';
import '../../dashboard/domain/dashboard_layout.dart';
import '../../dashboard/domain/dashboard_room.dart';
import '../domain/core_layout_archive.dart';

/// Explicit local archive operations on one current Core/home/user repository.
/// The caller owns source, session, PIN, route and window lifetime checks.
/// No Server resource, credential, journal or legacy storage is read or written.
class CoreLayoutArchiveController {
  CoreLayoutArchiveController({
    required DashboardRepository destination,
    required bool Function() isCurrent,
    DateTime Function()? clock,
  }) : _destination = destination,
       _isCurrent = isCurrent,
       _clock = clock ?? DateTime.now {
    if (destination.scope == null) {
      throw const DashboardStorageException('expired');
    }
  }

  static const lifetime = Duration(minutes: 5);
  final DashboardRepository _destination;
  final bool Function() _isCurrent;
  final DateTime Function() _clock;
  final Object _owner = Object();
  bool _closed = false;

  void close() => _closed = true;

  void _check() {
    try {
      if (!_closed && _isCurrent()) return;
    } catch (_) {
      // Failed owner checks convey no authority or private error contents.
    }
    _closed = true;
    throw const DashboardStorageException('expired');
  }

  DateTime _timestamp() => DateTime.fromMillisecondsSinceEpoch(
    _clock().millisecondsSinceEpoch,
    isUtc: true,
  );

  CoreLayoutArchiveV1 _passive(DashboardSnapshot snapshot) =>
      CoreLayoutArchiveV1.fromScopedLayout(
        scope: _destination.scope!,
        sourceRevision: snapshot.revision,
        capturedAt: _timestamp(),
        layout: snapshot.layout.toJson(),
      );

  Future<CoreLayoutArchiveV1> capture() => ConfigurationWrites.run(() async {
    _check();
    final snapshot = await _destination.readSnapshot();
    _check();
    final archive = _passive(snapshot);
    _check();
    return archive;
  });

  Future<CoreLayoutArchivePreview> preview(CoreLayoutArchiveV1 archive) =>
      ConfigurationWrites.run(() async {
        _check();
        if (!archive.matchesScope(_destination.scope!)) {
          throw const DashboardStorageException('scope_mismatch');
        }
        final target = await _destination.readSnapshot();
        _check();
        // A room-only archive cannot silently erase richer current contents.
        _passive(target);
        final preview = CoreLayoutArchivePreview._(
          _owner,
          target,
          archive,
          _clock(),
        );
        _check();
        return preview;
      });

  void _checkPreview(CoreLayoutArchivePreview preview) {
    _check();
    final elapsed = _clock().difference(preview.createdAt);
    if (!identical(preview._owner, _owner) ||
        elapsed < Duration.zero ||
        elapsed >= lifetime) {
      throw const DashboardStorageException('expired');
    }
  }

  Future<void> apply(CoreLayoutArchivePreview preview) {
    // Every attempted confirmation consumes its own preview before queuing.
    // A foreign controller cannot consume another owner's valid preview.
    try {
      _checkPreview(preview);
      if (preview._used) throw const DashboardStorageException('expired');
      preview._used = true;
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    return ConfigurationWrites.run(() async {
      _checkPreview(preview);
      final restored = DashboardLayout(
        rooms: [
          for (final room in preview._archive.rooms)
            DashboardRoom(id: room.id, name: room.name),
        ],
      );
      bool current() {
        _checkPreview(preview);
        return true;
      }
      await _destination.saveIfUnchanged(
        restored,
        expected: preview._target,
        isCurrent: current,
      );
      _checkPreview(preview);
      final observed = await _destination.readSnapshot();
      _checkPreview(preview);
      if (observed.revision != preview._target.revision + 1 ||
          observed.layout != restored) {
        throw const DashboardStorageException('write_failed');
      }
      // An uncertain false/throw/readback outcome is not rolled back or retried.
      // The caller must request a fresh preview/read after any such outcome.
    });
  }

  @override
  String toString() => 'CoreLayoutArchiveController';
}

final class CoreLayoutArchivePreview {
  CoreLayoutArchivePreview._(
    this._owner,
    this._target,
    this._archive,
    this.createdAt,
  );
  final Object _owner;
  final DashboardSnapshot _target;
  final CoreLayoutArchiveV1 _archive;
  final DateTime createdAt;
  bool _used = false;

  List<String> get currentRoomNames =>
      List.unmodifiable(_target.layout.rooms.map((room) => room.name));
  List<String> get archivedRoomNames =>
      List.unmodifiable(_archive.rooms.map((room) => room.name));

  @override
  String toString() => 'CoreLayoutArchivePreview';
}
