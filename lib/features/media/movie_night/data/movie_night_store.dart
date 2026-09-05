import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/configuration_writes.dart';
import '../../../../core/direct_home_access.dart';
import '../domain/movie_night_preset.dart';

class MovieNightStore {
  // Preserve a public constructor argument with private stored ownership.
  // ignore: prefer_initializing_formals
  MovieNightStore({DirectHomeAccess? access}) : _access = access;
  final DirectHomeAccess? _access;

  void _check([bool Function()? isCurrent]) {
    _access?.check();
    if (isCurrent != null && !isCurrent()) {
      throw StateError('Movie night settings changed');
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

  Future<MovieNightPreset?> read() => ConfigurationWrites.run(() async {
    final prefs = await _preferences();
    final value = prefs.get(MovieNightPreset.storageKey);
    return value == null ? null : MovieNightPreset.decodeStored(value);
  });

  Future<void> save(
    MovieNightPreset preset, {
    required bool Function() isCurrent,
  }) {
    final encoded = preset.encodeStored();
    return ConfigurationWrites.run(() async {
      _check(isCurrent);
      final prefs = await _preferences();
      _check(isCurrent);
      try {
        final accepted = await _io(
          () => prefs.setString(MovieNightPreset.storageKey, encoded),
          mutation: true,
        );
        if (!accepted)
          throw const DirectHomeAccessException('write_unconfirmed');
        _check(isCurrent);
      } catch (_) {
        // The complete single-key value may have committed; never retry or
        // overwrite it with an old snapshot on an uncertain response.
        throw const DirectHomeAccessException('write_unconfirmed');
      }
    });
  }
}
