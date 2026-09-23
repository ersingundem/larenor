// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/configuration_writes.dart';
import '../../../../core/direct_home_access.dart';
import '../domain/jellyfin_track_preferences.dart';
import 'jellyfin_config.dart';

/// Sanitized choices from the former device-local Jellyfin preference record.
///
/// It deliberately carries no source URL, user, device or credential. Reading
/// a preview never adopts or deletes the old record; a later user-confirmed
/// transition owns those mutations.
final class LegacyJellyfinTrackPreferencesPreview {
  const LegacyJellyfinTrackPreferencesPreview({
    required this.audioLanguage,
    required this.subtitleLanguage,
  });

  final String? audioLanguage;
  final String? subtitleLanguage;

  @override
  String toString() => 'Legacy Jellyfin track preference preview';
}

/// Read-only bridge for records written before track preferences moved to Core.
final class LegacyJellyfinTrackPreferencesPreviewReader {
  // Preserve a public argument name while keeping the capability private.
  LegacyJellyfinTrackPreferencesPreviewReader({DirectHomeAccess? access})
    : _access = access;

  static const _maximumRecordBytes = 128;
  final DirectHomeAccess? _access;

  void _check(bool Function() isCurrent) {
    _access?.check();
    try {
      if (isCurrent()) return;
    } catch (_) {
      // A throwing authority callback is a denial.
    }
    throw StateError('Jellyfin preference scope changed');
  }

  Future<T> _storage<T>(Future<T> Function() operation) =>
      _access == null ? operation() : _access.storage(operation);

  String? _storageKey(JellyfinConfig config) {
    if (config.baseUrl.isEmpty ||
        config.baseUrl.length > 2048 ||
        config.userId.isEmpty ||
        config.userId.length > 256) {
      return null;
    }
    final scope = sha256.convert(
      utf8.encode('${config.baseUrl}\u0000${config.userId}'),
    );
    return 'jellyfin_track_languages_v1_$scope';
  }

  Future<LegacyJellyfinTrackPreferencesPreview?> read(
    JellyfinConfig config, {
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    _check(isCurrent);
    final preferences = await _storage(SharedPreferences.getInstance);
    _check(isCurrent);
    await _storage(preferences.reload);
    _check(isCurrent);
    final key = _storageKey(config);
    if (key == null) return null;
    final raw = preferences.get(key);
    _check(isCurrent);
    if (raw is! String ||
        raw.length > _maximumRecordBytes ||
        utf8.encode(raw).length > _maximumRecordBytes) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded.length != 3 ||
          !decoded.keys.every(
            const {'version', 'audio', 'subtitle'}.contains,
          ) ||
          decoded['version'] != 1 ||
          decoded['audio'] != null && decoded['audio'] is! String ||
          decoded['subtitle'] != null && decoded['subtitle'] is! String) {
        return null;
      }
      final audio = JellyfinTrackPreferences.normalize(
        decoded['audio'] as String?,
      );
      final subtitle = JellyfinTrackPreferences.normalize(
        decoded['subtitle'] as String?,
        allowOff: true,
      );
      if (audio == null && subtitle == null) return null;
      _check(isCurrent);
      return LegacyJellyfinTrackPreferencesPreview(
        audioLanguage: audio,
        subtitleLanguage: subtitle,
      );
    } on FormatException {
      return null;
    }
  });
}
