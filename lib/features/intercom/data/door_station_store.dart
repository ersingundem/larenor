import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/configuration_writes.dart';
import '../domain/door_station.dart';

class DoorStationStore {
  Future<List<DoorStation>> read() => ConfigurationWrites.run(() async {
    final raw = (await SharedPreferences.getInstance()).get(
      DoorStation.storageKey,
    );
    if (raw == null) return const [];
    return DoorStation.decodeStored(raw);
  });

  Future<void> save(List<DoorStation> stations, {bool Function()? isCurrent}) {
    // Freeze and validate before queueing; callers cannot mutate a queued list.
    final encoded = DoorStation.encodeStored(stations);
    void checkCurrent() {
      if (isCurrent != null && !isCurrent()) {
        throw StateError('Station configuration changed.');
      }
    }

    return ConfigurationWrites.run(() async {
      checkCurrent();
      final prefs = await SharedPreferences.getInstance();
      checkCurrent();
      if (!await prefs.setString(DoorStation.storageKey, encoded)) {
        throw StateError('Station configuration could not be saved.');
      }
    });
  }

  /// Read-modify-write remains inside the same process-wide transaction.
  Future<void> upsert(DoorStation station, {bool Function()? isCurrent}) {
    final validated = DoorStation.fromJson(station.toJson());
    return ConfigurationWrites.run(() async {
      if (isCurrent != null && !isCurrent()) {
        throw StateError('Station configuration changed.');
      }
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
        if (isCurrent != null && !isCurrent()) {
          throw StateError('Station configuration changed.');
        }
        final current = await read();
        await save([
          for (final value in current)
            if (value.id != id) value,
        ], isCurrent: isCurrent);
      });
}
