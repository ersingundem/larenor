import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/configuration_writes.dart';
import '../../../core/direct_home_access.dart';
import '../domain/door_station.dart';

class DoorStationStore {
  // Preserve a public constructor argument with private stored ownership.
  // ignore: prefer_initializing_formals
  DoorStationStore({DirectHomeAccess? access}) : _access = access;
  final DirectHomeAccess? _access;

  void _check([bool Function()? isCurrent]) {
    _access?.check();
    if (isCurrent != null && !isCurrent()) {
      throw StateError('Station configuration changed.');
    }
  }

  Future<T> _io<T>(
    Future<T> Function() operation, {
    bool mutation = false,
  }) async {
    if (_access != null) return _access.storage(operation, mutation: mutation);
    try {
      return await operation();
    } catch (_) {
      throw DirectHomeAccessException(
        mutation ? 'write_unconfirmed' : 'storage_failed',
      );
    }
  }

  Future<SharedPreferences> _preferences() async {
    _check();
    final prefs = await _io(SharedPreferences.getInstance);
    await _io(prefs.reload);
    _check();
    return prefs;
  }

  Future<List<DoorStation>> read() => ConfigurationWrites.run(() async {
    final prefs = await _preferences();
    _check(); // Recheck in this continuation before consuming the cache.
    final raw = prefs.get(DoorStation.storageKey);
    if (raw == null) return const [];
    return DoorStation.decodeStored(raw);
  });

  Future<void> save(List<DoorStation> stations, {bool Function()? isCurrent}) {
    // Freeze and validate before queueing; callers cannot mutate a queued list.
    final encoded = DoorStation.encodeStored(stations);
    return ConfigurationWrites.run(() async {
      _check(isCurrent);
      final prefs = await _preferences();
      _check(isCurrent);
      try {
        final accepted = await _io(
          () => prefs.setString(DoorStation.storageKey, encoded),
          mutation: true,
        );
        if (!accepted) {
          throw const DirectHomeAccessException('write_unconfirmed');
        }
        _check(isCurrent);
      } catch (_) {
        // A single preference may already have committed. Do not restore an
        // older value or publish success after a lost response/ownership.
        throw const DirectHomeAccessException('write_unconfirmed');
      }
    });
  }

  /// Read-modify-write remains inside the same process-wide transaction.
  Future<void> upsert(DoorStation station, {bool Function()? isCurrent}) {
    final validated = DoorStation.fromJson(station.toJson());
    return ConfigurationWrites.run(() async {
      _check(isCurrent);
      final current = await read();
      await save([
        for (final value in current)
          if (value.id != validated.id) value,
        validated,
      ], isCurrent: isCurrent);
    });
  }

  Future<void> remove(String id, {bool Function()? isCurrent}) =>
      ConfigurationWrites.run(() async {
        _check(isCurrent);
        final current = await read();
        await save([
          for (final value in current)
            if (value.id != id) value,
        ], isCurrent: isCurrent);
      });
}
