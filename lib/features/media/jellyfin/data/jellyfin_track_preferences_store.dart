import 'package:flutter_riverpod/flutter_riverpod.dart';

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

final class _CorePreferenceSnapshot {
  const _CorePreferenceSnapshot(this.value, this.revision);
  final JellyfinTrackPreferenceRecord value;
  final int revision;
}

final class _JellyfinTrackPreferencesApi {
  const _JellyfinTrackPreferencesApi(this.api, this.session);
  final LarenorServerApi api;
  final ServerSession session;

  ServerContext get _context =>
      session.context ??
      (throw const LarenorServerException('context_pending'));

  String get _root =>
      '/media/jellyfin/preferences/${_context.coreId}/${_context.homeId}';

  Map<String, dynamic> _object(Object? value, Set<String> keys) {
    final result = serverObject(value);
    if (result.length != keys.length || !result.keys.every(keys.contains)) {
      throw const LarenorServerException('invalid_response');
    }
    return result;
  }

  String _identity(Object? value) {
    if (value is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  int _revision(Object? value) {
    if (value is! int || value < 1 || value > 0x7fffffffffffffff) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  String? _language(Object? value, {bool off = false}) {
    if (value == null) return null;
    if (value is! String) {
      throw const LarenorServerException('invalid_response');
    }
    try {
      final normalized = JellyfinTrackPreferences.normalize(
        value,
        allowOff: off,
      );
      if (normalized != value) {
        throw const LarenorServerException('invalid_response');
      }
      return normalized;
    } on FormatException {
      throw const LarenorServerException('invalid_response');
    }
  }

  _CorePreferenceSnapshot? _response(Object? value) {
    final result = _object(value, {'schemaVersion', 'authority', 'preference'});
    if (result['schemaVersion'] != 1) {
      throw const LarenorServerException('invalid_response');
    }
    final authority = _object(result['authority'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'accountRevision',
      'sessionFamilyId',
    });
    if (authority['schemaVersion'] != 1 ||
        _identity(authority['coreId']) != _context.coreId ||
        _identity(authority['homeId']) != _context.homeId ||
        _identity(authority['accountId']) != session.user.id) {
      throw const LarenorServerException('invalid_response');
    }
    _revision(authority['accountRevision']);
    _identity(authority['sessionFamilyId']);
    if (result['preference'] == null) return null;
    final preference = _object(result['preference'], {
      'schemaVersion',
      'ref',
      'revision',
      'audioLanguage',
      'subtitleLanguage',
    });
    final ref = _object(preference['ref'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'kind',
    });
    if (preference['schemaVersion'] != 1 ||
        ref['schemaVersion'] != 1 ||
        _identity(ref['coreId']) != _context.coreId ||
        _identity(ref['homeId']) != _context.homeId ||
        _identity(ref['accountId']) != session.user.id ||
        ref['kind'] != 'jellyfin_track_preferences') {
      throw const LarenorServerException('invalid_response');
    }
    final audio = _language(preference['audioLanguage']);
    final subtitle = _language(preference['subtitleLanguage'], off: true);
    if (audio == null && subtitle == null) {
      throw const LarenorServerException('invalid_response');
    }
    return _CorePreferenceSnapshot(
      JellyfinTrackPreferenceRecord(
        audioLanguage: audio,
        subtitleLanguage: subtitle,
      ),
      _revision(preference['revision']),
    );
  }

  Future<_CorePreferenceSnapshot?> read() async =>
      _response(await api.request('GET', _root, token: session.accessToken));

  Future<_CorePreferenceSnapshot> write({
    required int expectedRevision,
    required String? audioLanguage,
    required String? subtitleLanguage,
  }) async {
    final result = _response(
      await api.request(
        'PUT',
        _root,
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'expectedRevision': expectedRevision,
          'audioLanguage': audioLanguage,
          'subtitleLanguage': subtitleLanguage,
        },
      ),
    );
    if (result == null || result.revision != expectedRevision + 1) {
      throw const LarenorServerException('invalid_response');
    }
    return result;
  }
}

/// Core-owned playback languages. The direct Jellyfin identity is accepted by
/// the legacy caller shape but is never used as storage scope or sent on wire.
class JellyfinTrackPreferencesStore {
  JellyfinTrackPreferencesStore({this.account});

  final ServerAccountController? account;

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

  Future<JellyfinTrackPreferenceRecord?> read(
    JellyfinConfig config, {
    required bool Function() isCurrent,
  }) async {
    _check(isCurrent);
    final result = await _requiredAccount.withSession((api, session) async {
      _check(isCurrent);
      final value = await _JellyfinTrackPreferencesApi(api, session).read();
      _check(isCurrent);
      return value?.value;
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

  Future<JellyfinTrackPreferenceRecord> _save(
    JellyfinConfig config, {
    String? audioLanguage,
    String? subtitleLanguage,
    required bool Function() isCurrent,
  }) async {
    if ((audioLanguage == null) == (subtitleLanguage == null)) {
      throw const FormatException('Exactly one preference is required');
    }
    _check(isCurrent);
    final result = await _requiredAccount.withSession((api, session) async {
      final client = _JellyfinTrackPreferencesApi(api, session);
      _check(isCurrent);
      final old = await client.read();
      _check(isCurrent);
      final audio = audioLanguage ?? old?.value.audioLanguage;
      final subtitle = subtitleLanguage ?? old?.value.subtitleLanguage;
      final saved = await client.write(
        expectedRevision: old?.revision ?? 0,
        audioLanguage: audio,
        subtitleLanguage: subtitle,
      );
      _check(isCurrent);
      if (saved.value.audioLanguage != audio ||
          saved.value.subtitleLanguage != subtitle) {
        throw const LarenorServerException('invalid_response');
      }
      return saved.value;
    });
    _check(isCurrent);
    return result;
  }
}
