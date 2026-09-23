import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../language_preferences/data/core_media_language_preferences_api.dart';
import '../../language_preferences/domain/core_media_language_preferences.dart';
import '../../../server/data/larenor_server_api.dart';
import '../../../server/data/server_account_controller.dart';
import '../../../server/domain/server_models.dart';
import '../../../server/providers/server_providers.dart';
import '../domain/jellyfin_track_preferences.dart';
import 'jellyfin_config.dart';

final jellyfinTrackPreferencesStoreProvider =
    Provider<JellyfinTrackPreferencesStore>(
      (ref) => JellyfinTrackPreferencesStore(
        account: ref.watch(serverAccountControllerProvider),
      ),
    );

/// Core-owned playback languages. The direct Jellyfin identity is accepted by
/// the legacy caller shape but is never used as storage scope or sent on wire.
class JellyfinTrackPreferencesStore {
  JellyfinTrackPreferencesStore({this.account, Random? random})
    : _random = random ?? Random.secure();

  final ServerAccountController? account;
  final Random _random;

  void _check(bool Function() isCurrent) {
    try {
      if (isCurrent()) return;
    } catch (_) {
      // A throwing route authority is a denial.
    }
    throw StateError('Jellyfin preference scope changed');
  }

  ServerAccountController get _requiredAccount =>
      account ?? (throw StateError('Core account unavailable'));

  CoreMediaLanguagePreferencesApi _client(
    ServerSession session,
    LarenorServerApi api,
  ) {
    final context = session.context;
    final sessionFamilyId = session.sessionFamilyId;
    if (context == null || sessionFamilyId == null) {
      throw const LarenorServerException('context_pending');
    }
    return CoreMediaLanguagePreferencesApi(
      api,
      session.accessToken,
      context,
      session.user.id,
      sessionFamilyId,
    );
  }

  JellyfinTrackPreferenceRecord? _record(CoreMediaLanguageSnapshot snapshot) {
    final preference = snapshot.preference;
    if (preference == null) return null;
    return JellyfinTrackPreferenceRecord(
      audioLanguage: preference.audioLanguage,
      subtitleLanguage: preference.subtitleLanguage,
    );
  }

  String _requestId() => List.generate(
    32,
    (_) => _random.nextInt(16).toRadixString(16),
    growable: false,
  ).join();

  bool _mayHaveCommitted(Object error) =>
      error is LarenorServerException &&
      const {
        'connection_failed',
        'timeout',
        'server_error',
      }.contains(error.code);

  Future<JellyfinTrackPreferenceRecord?> read(
    JellyfinConfig config, {
    required bool Function() isCurrent,
  }) async {
    _check(isCurrent);
    final result = await _requiredAccount.withSession((api, session) async {
      _check(isCurrent);
      final value = await _client(session, api).read();
      _check(isCurrent);
      return _record(value);
    });
    _check(isCurrent);
    return result;
  }

  Future<JellyfinTrackPreferenceRecord> saveAudio(
    JellyfinConfig config, {
    required String language,
    required bool Function() isCurrent,
  }) => _save(
    config,
    audioLanguage: JellyfinTrackPreferences.normalize(language),
    isCurrent: isCurrent,
  );

  Future<JellyfinTrackPreferenceRecord> saveSubtitle(
    JellyfinConfig config, {
    required String language,
    required bool Function() isCurrent,
  }) => _save(
    config,
    subtitleLanguage: JellyfinTrackPreferences.normalize(
      language,
      allowOff: true,
    ),
    isCurrent: isCurrent,
  );

  /// Applies the non-null choices from an explicitly confirmed legacy record.
  ///
  /// The current Core record is always read inside the live account session so
  /// a missing legacy field preserves the latest same-account sibling choice.
  /// An already-applied merge is returned without replaying its PUT.
  Future<JellyfinTrackPreferenceRecord> mergeLegacy(
    JellyfinConfig config, {
    String? audioLanguage,
    String? subtitleLanguage,
    required bool Function() isCurrent,
  }) {
    final audio = JellyfinTrackPreferences.normalize(audioLanguage);
    final subtitle = JellyfinTrackPreferences.normalize(
      subtitleLanguage,
      allowOff: true,
    );
    if (audio == null && subtitle == null) {
      throw const FormatException('At least one preference is required');
    }
    return _merge(
      config,
      audioLanguage: audio,
      subtitleLanguage: subtitle,
      skipUnchanged: true,
      isCurrent: isCurrent,
    );
  }

  Future<JellyfinTrackPreferenceRecord> _save(
    JellyfinConfig config, {
    String? audioLanguage,
    String? subtitleLanguage,
    required bool Function() isCurrent,
  }) async {
    if ((audioLanguage == null) == (subtitleLanguage == null)) {
      throw const FormatException('Exactly one preference is required');
    }
    return _merge(
      config,
      audioLanguage: audioLanguage,
      subtitleLanguage: subtitleLanguage,
      skipUnchanged: false,
      isCurrent: isCurrent,
    );
  }

  Future<JellyfinTrackPreferenceRecord> _merge(
    JellyfinConfig config, {
    String? audioLanguage,
    String? subtitleLanguage,
    required bool skipUnchanged,
    required bool Function() isCurrent,
  }) async {
    _check(isCurrent);
    final result = await _requiredAccount.withSession((api, session) async {
      final client = _client(session, api);
      _check(isCurrent);
      final base = await client.read();
      _check(isCurrent);
      final old = _record(base);
      final audio = audioLanguage ?? old?.audioLanguage;
      final subtitle = subtitleLanguage ?? old?.subtitleLanguage;
      if (skipUnchanged &&
          old != null &&
          old.audioLanguage == audio &&
          old.subtitleLanguage == subtitle) {
        return old;
      }
      if (audio == null && subtitle == null) {
        throw const LarenorServerException('invalid_request');
      }
      final requestId = _requestId();
      CoreMediaLanguageSnapshot saved;
      try {
        saved = await client.save(
          base: base,
          requestId: requestId,
          audioLanguage: audio,
          subtitleLanguage: subtitle,
        );
      } catch (error) {
        if (!_mayHaveCommitted(error)) rethrow;
        _check(isCurrent);
        saved = await client.save(
          base: base,
          requestId: requestId,
          audioLanguage: audio,
          subtitleLanguage: subtitle,
        );
      }
      _check(isCurrent);
      final value = _record(saved);
      if (value == null ||
          value.audioLanguage != audio ||
          value.subtitleLanguage != subtitle) {
        throw const LarenorServerException('invalid_response');
      }
      return value;
    });
    _check(isCurrent);
    return result;
  }
}
