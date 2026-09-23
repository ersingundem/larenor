import '../../../server/data/larenor_server_api.dart';
import '../../../server/domain/server_models.dart';
import '../domain/core_media_language_preferences.dart';

final class CoreMediaLanguagePreferencesApi {
  const CoreMediaLanguagePreferencesApi(
    this._api,
    this._token,
    this._context,
    this._accountId,
  );

  final LarenorServerApi _api;
  final String _token;
  final ServerContext _context;
  final String _accountId;

  String get _path =>
      '/media/language-preferences/${_context.coreId}/${_context.homeId}';

  Future<CoreMediaLanguageSnapshot> read() async =>
      CoreMediaLanguageSnapshot.fromJson(
        await _api.request('GET', _path, token: _token),
        context: _context,
        accountId: _accountId,
      );

  Future<CoreMediaLanguageSnapshot> save({
    required CoreMediaLanguageSnapshot base,
    required String requestId,
    required String? audioLanguage,
    required String? subtitleLanguage,
  }) async {
    final audio = coreMediaLanguage(audioLanguage);
    final subtitle = coreMediaLanguage(subtitleLanguage, allowOff: true);
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId) ||
        base.authority.context != _context ||
        base.authority.accountId != _accountId ||
        audio == null && subtitle == null) {
      throw const LarenorServerException('invalid_request');
    }
    final result = CoreMediaLanguageSnapshot.fromJson(
      await _api.request(
        'PUT',
        _path,
        token: _token,
        body: {
          'schemaVersion': 1,
          'requestId': requestId,
          'expectedAccountRevision': base.authority.accountRevision,
          'expectedRevision': base.authority.preferenceRevision,
          'audioLanguage': audio,
          'subtitleLanguage': subtitle,
        },
      ),
      context: _context,
      accountId: _accountId,
    );
    final before = base.authority;
    final after = result.authority;
    final saved = result.preference;
    if (after.sessionFamilyId != before.sessionFamilyId ||
        after.accountRevision != before.accountRevision ||
        after.preferenceRevision != before.preferenceRevision + 1 ||
        saved == null ||
        saved.audioLanguage != audio ||
        saved.subtitleLanguage != subtitle) {
      throw const LarenorServerException('invalid_response');
    }
    return result;
  }
}
