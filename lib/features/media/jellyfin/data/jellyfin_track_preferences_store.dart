import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/configuration_writes.dart';
import '../../../../core/direct_home_access.dart';
import '../domain/jellyfin_track_preferences.dart';
import 'jellyfin_config.dart';

final jellyfinTrackPreferencesStoreProvider =
    Provider<JellyfinTrackPreferencesStore>(
      (ref) => JellyfinTrackPreferencesStore(
        access: ref.watch(directHomeAccessProvider),
      ),
    );

/// Non-secret local preferences scoped to one Jellyfin endpoint and account.
/// DirectHomeAccess and the caller's route/session guard retire stale writes.
class JellyfinTrackPreferencesStore {
  // Preserve a public constructor name while owning the private capability.
  // ignore: prefer_initializing_formals
  JellyfinTrackPreferencesStore({DirectHomeAccess? access}) : _access = access;

  final DirectHomeAccess? _access;

  String _key(JellyfinConfig config) {
    final scope = sha256.convert(
      utf8.encode('${config.baseUrl}\u0000${config.userId}'),
    );
    return 'jellyfin_track_languages_v1_$scope';
  }

  void _check(bool Function() isCurrent) {
    _access?.check();
    try {
      if (isCurrent()) return;
    } catch (_) {
      // A throwing authority guard is a denial.
    }
    throw StateError('Jellyfin preference scope changed');
  }

  Future<SharedPreferences> _preferences(bool Function() isCurrent) async {
    _check(isCurrent);
    final preferences = _access == null
        ? await SharedPreferences.getInstance()
        : await _access.storage(SharedPreferences.getInstance);
    _check(isCurrent);
    await preferences.reload();
    _check(isCurrent);
    return preferences;
  }

  Future<JellyfinTrackPreferenceRecord?> read(
    JellyfinConfig config, {
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    final preferences = await _preferences(isCurrent);
    final raw = preferences.getString(_key(config));
    _check(isCurrent);
    if (raw == null || raw.length > 128) return null;
    try {
      final record = jsonDecode(raw);
      if (record is! Map<String, dynamic> ||
          record['version'] != 1 ||
          record.keys.any(
            (key) => !const {'version', 'audio', 'subtitle'}.contains(key),
          )) {
        return null;
      }
      final audio = record['audio'];
      final subtitle = record['subtitle'];
      if (audio != null && audio is! String ||
          subtitle != null && subtitle is! String) {
        return null;
      }
      return JellyfinTrackPreferenceRecord(
        audioLanguage: JellyfinTrackPreferences.normalize(audio as String?),
        subtitleLanguage: JellyfinTrackPreferences.normalize(
          subtitle as String?,
          allowOff: true,
        ),
      );
    } on FormatException {
      return null;
    }
  });

  Future<void> save(
    JellyfinConfig config, {
    required String? audioLanguage,
    required String? subtitleLanguage,
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    final audio = JellyfinTrackPreferences.normalize(audioLanguage);
    final subtitle = JellyfinTrackPreferences.normalize(
      subtitleLanguage,
      allowOff: true,
    );
    final value = jsonEncode({
      'version': 1,
      'audio': audio,
      'subtitle': subtitle,
    });
    final preferences = await _preferences(isCurrent);
    _check(isCurrent);
    final accepted = _access == null
        ? await preferences.setString(_key(config), value)
        : await _access.storage(
            () => preferences.setString(_key(config), value),
            mutation: true,
          );
    _check(isCurrent);
    if (!accepted) throw StateError('Jellyfin preference write unconfirmed');
  });
}
