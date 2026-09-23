import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/configuration_writes.dart';
import '../../../../core/direct_home_access.dart';
import '../../../../shared/network/server_bound_client.dart';
import '../domain/movie_night_preset.dart';

class MovieNightStore {
  factory MovieNightStore({
    DirectHomeAccess? access,
    DateTime Function()? now,
  }) => MovieNightStore._(access, now ?? DateTime.now);

  MovieNightStore._(this._access, this._now);

  static const maximumBytes = 8 * 1024;
  static const timeToLive = Duration(days: 30);

  final DirectHomeAccess? _access;
  final DateTime Function() _now;

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

  Future<SharedPreferences> _preferences({bool Function()? isCurrent}) async {
    _check(isCurrent);
    final prefs = await _io(SharedPreferences.getInstance);
    _check(isCurrent);
    await _io(prefs.reload);
    _check(isCurrent);
    return prefs;
  }

  Future<MovieNightPreset?> read({
    String? serverUrl,
    bool Function()? isCurrent,
  }) => ConfigurationWrites.run(() async {
    final expected = serverUrl == null
        ? null
        : parseServerUrl(serverUrl).toString();
    final prefs = await _preferences(isCurrent: isCurrent);
    _check(isCurrent);
    final raw = prefs.get(MovieNightPreset.storageKey);
    if (raw == null) return null;
    if (raw is! String || utf8.encode(raw).length > maximumBytes) {
      await _clearIfCurrent(prefs, raw, isCurrent);
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      // Existing installations keep their strict legacy preset until the next
      // explicit save, which writes the bounded scoped envelope below.
      if (decoded is Map<String, dynamic> && decoded.containsKey('version')) {
        final preset = MovieNightPreset.decodeStored(raw);
        _check(isCurrent);
        return expected == null || preset.serverUrl == expected ? preset : null;
      }
      final record = _object(decoded, {
        'schemaVersion',
        'scope',
        'resource',
        'savedAt',
        'preset',
      });
      if (record['schemaVersion'] is! int || record['schemaVersion'] != 1) {
        throw const FormatException();
      }
      final scope = _object(record['scope'], {'serverUrl'});
      final scopedUrl = parseServerUrl(_text(scope['serverUrl'], 2048))
          .toString();
      if (expected != null && scopedUrl != expected) return null;
      final resource = _object(record['resource'], {'kind', 'revision'});
      if (resource['kind'] != 'movie_night_preset' ||
          resource['revision'] is! int ||
          resource['revision'] != 1) {
        throw const FormatException();
      }
      final savedAt = record['savedAt'] is String
          ? DateTime.tryParse(record['savedAt'] as String)
          : null;
      final instant = _now().toUtc();
      if (savedAt == null ||
          !savedAt.isUtc ||
          savedAt.toIso8601String() != record['savedAt'] ||
          instant.isBefore(savedAt) ||
          !instant.isBefore(savedAt.add(timeToLive))) {
        throw const FormatException();
      }
      final preset = MovieNightPreset.decodeStored(
        jsonEncode(_presetObject(record['preset'])),
      );
      if (preset.serverUrl != scopedUrl) throw const FormatException();
      _check(isCurrent);
      return preset;
    } catch (_) {
      _check(isCurrent);
      await _clearIfCurrent(prefs, raw, isCurrent);
      return null;
    }
  });

  Future<void> _clearIfCurrent(
    SharedPreferences prefs,
    Object raw,
    bool Function()? isCurrent,
  ) async {
    _check(isCurrent);
    if (prefs.get(MovieNightPreset.storageKey) != raw) return;
    try {
      await _io(
        () => prefs.remove(MovieNightPreset.storageKey),
        mutation: true,
      );
    } catch (_) {
      // Invalid local data stays fail-closed if best-effort cleanup is
      // unavailable. Never expose its contents through an error.
    }
    _check(isCurrent);
  }

  Future<void> save(
    MovieNightPreset preset, {
    required bool Function() isCurrent,
  }) {
    final canonical = MovieNightPreset.decodeStored(preset.encodeStored());
    final canonicalUrl = canonical.serverUrl;
    final encoded = jsonEncode({
      'schemaVersion': 1,
      'scope': {'serverUrl': canonicalUrl},
      'resource': {'kind': 'movie_night_preset', 'revision': 1},
      'savedAt': _now().toUtc().toIso8601String(),
      'preset': canonical.toJson(),
    });
    if (utf8.encode(encoded).length > maximumBytes) {
      throw StateError('Movie night settings exceed the local quota');
    }
    return ConfigurationWrites.run(() async {
      _check(isCurrent);
      final prefs = await _preferences(isCurrent: isCurrent);
      _check(isCurrent);
      try {
        final accepted = await _io(
          () => prefs.setString(MovieNightPreset.storageKey, encoded),
          mutation: true,
        );
        if (!accepted) {
          throw const DirectHomeAccessException('write_unconfirmed');
        }
        _check(isCurrent);
      } catch (_) {
        // The complete single-key value may have committed; never retry or
        // overwrite it with an old snapshot on an uncertain response.
        throw const DirectHomeAccessException('write_unconfirmed');
      }
    });
  }
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    throw const FormatException('Invalid movie night settings');
  }
  return value;
}

Map<String, dynamic> _presetObject(Object? value) {
  const required = {'version', 'serverUrl', 'startEntityId'};
  const allowed = {...required, 'finishEntityId'};
  if (value is! Map<String, dynamic> ||
      !value.keys.every(allowed.contains) ||
      !value.keys.toSet().containsAll(required) ||
      value['version'] is! int ||
      value['version'] != 1) {
    throw const FormatException('Invalid movie night settings');
  }
  return value;
}

String _text(Object? value, int maximum) {
  if (value is! String ||
      value.isEmpty ||
      value.length > maximum ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw const FormatException('Invalid movie night settings');
  }
  return value;
}
