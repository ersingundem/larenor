import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/configuration_writes.dart';
import '../domain/movie_night_preset.dart';

class MovieNightStore {
  Future<MovieNightPreset?> read() => ConfigurationWrites.run(() async {
    final value = (await SharedPreferences.getInstance()).get(
      MovieNightPreset.storageKey,
    );
    return value == null ? null : MovieNightPreset.decodeStored(value);
  });

  Future<void> save(
    MovieNightPreset preset, {
    required bool Function() isCurrent,
  }) {
    final encoded = preset.encodeStored();
    return ConfigurationWrites.run(() async {
      if (!isCurrent()) throw StateError('Movie night settings changed');
      final prefs = await SharedPreferences.getInstance();
      if (!isCurrent()) throw StateError('Movie night settings changed');
      if (!await prefs.setString(MovieNightPreset.storageKey, encoded)) {
        throw StateError('Movie night settings could not be saved');
      }
    });
  }
}
