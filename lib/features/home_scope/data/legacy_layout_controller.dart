import 'dart:math';

import '../../../core/configuration_writes.dart';
import '../../dashboard/data/dashboard_repository.dart';
import '../../dashboard/domain/dashboard_room.dart';

/// Explicit local read only: no credential store, HA client or discovery input.
class LegacyLayoutController {
  LegacyLayoutController({
    required DashboardRepository destination,
    required bool Function() isCurrent,
    DateTime Function()? clock,
  }) : _destination = destination,
       _current = isCurrent,
       _clock = clock ?? DateTime.now {
    if (destination.scope == null)
      throw const DashboardStorageException('expired');
  }
  static const lifetime = Duration(minutes: 5);
  final DashboardRepository _destination;
  final bool Function() _current;
  final DateTime Function() _clock;
  final _owner = Object();
  bool _closed = false;
  void close() => _closed = true;
  bool get _active => !_closed && _current();
  void _check() {
    if (!_active) throw const DashboardStorageException('expired');
  }

  Future<LegacyLayoutPreview> preview() => ConfigurationWrites.run(() async {
    _check();
    final source = await DashboardRepository(isCurrent: () => _active)
        .readSnapshot();
    _check();
    final target = await _destination.readSnapshot();
    _check();
    final layout = source.layout;
    return LegacyLayoutPreview._(
      _owner,
      source.fingerprint,
      target,
      _clock(),
      List.unmodifiable(layout.rooms.map((room) => room.name)),
      layout.rooms.fold<int>(0, (sum, room) => sum + room.entityIds.length) +
          layout.favoriteEntityIds.length +
          layout.hiddenEntityIds.length +
          layout.entityCardSizes.length,
      layout.rooms.where((room) => room.areaBinding != null).length,
      layout.tiles.length,
    );
  });

  bool _valid(LegacyLayoutPreview preview) {
    final elapsed = _clock().difference(preview.createdAt);
    return _active &&
        identical(preview._owner, _owner) &&
        elapsed >= Duration.zero &&
        elapsed < lifetime;
  }

  Future<void> apply(LegacyLayoutPreview preview, Set<int> selected) {
    final indices = Set<int>.of(selected);
    if (!_valid(preview) ||
        preview._used ||
        indices.isEmpty ||
        indices.any((i) => i < 0 || i >= preview.roomNames.length)) {
      return Future.error(const DashboardStorageException('expired'));
    }
    // Consume before queuing: every outcome requires a new explicit preview.
    preview._used = true;
    return ConfigurationWrites.run(() async {
      void check() {
        if (!_valid(preview)) throw const DashboardStorageException('expired');
      }

      check();
      final source = await DashboardRepository(isCurrent: () => _valid(preview))
          .readSnapshot();
      check();
      if (source.fingerprint != preview._sourceFingerprint) {
        throw const DashboardStorageException('changed');
      }
      final target = await _destination.readSnapshot();
      check();
      if (target.revision != preview._target.revision ||
          target.fingerprint != preview._target.fingerprint) {
        throw const DashboardStorageException('changed');
      }
      if (target.layout.rooms.length + indices.length > 500) {
        throw const DashboardStorageException('room_limit');
      }
      final random = Random.secure();
      final ids = target.layout.rooms.map((r) => r.id).toSet();
      String newId() {
        for (var attempt = 0; attempt < 4; attempt++) {
          final id = List.generate(
            16,
            (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
          if (ids.add(id)) return id;
        }
        throw const DashboardStorageException('write_failed');
      }

      final next = target.layout.copyWith(
        schemaVersion: 2,
        rooms: [
          ...target.layout.rooms,
          for (var i = 0; i < preview.roomNames.length; i++)
            if (indices.contains(i))
              DashboardRoom(id: newId(), name: preview.roomNames[i]),
        ],
      );
      await _destination.save(
        next,
        expected: preview._target,
        isCurrent: () => _valid(preview),
      );
      check();
    });
  }
}

final class LegacyLayoutPreview {
  LegacyLayoutPreview._(
    this._owner,
    this._sourceFingerprint,
    this._target,
    this.createdAt,
    this.roomNames,
    this.excludedEntityReferences,
    this.excludedAreaBindings,
    this.excludedCards,
  );
  final Object _owner;
  final String _sourceFingerprint;
  final DashboardSnapshot _target;
  final DateTime createdAt;
  final List<String> roomNames;
  final int excludedEntityReferences, excludedAreaBindings, excludedCards;
  bool _used = false;
  List<String> get currentRoomNames =>
      List.unmodifiable(_target.layout.rooms.map((r) => r.name));
  @override
  String toString() => 'LegacyLayoutPreview';
}
