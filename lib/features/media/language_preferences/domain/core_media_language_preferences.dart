import '../../../server/domain/server_models.dart';

final class CoreMediaLanguageAuthority {
  const CoreMediaLanguageAuthority({
    required this.context,
    required this.accountId,
    required this.sessionFamilyId,
    required this.accountRevision,
    required this.preferenceRevision,
  });

  final ServerContext context;
  final String accountId;
  final String sessionFamilyId;
  final int accountRevision;
  final int preferenceRevision;
}

final class CoreMediaLanguagePreference {
  const CoreMediaLanguagePreference({
    required this.revision,
    required this.audioLanguage,
    required this.subtitleLanguage,
  });

  final int revision;
  final String? audioLanguage;
  final String? subtitleLanguage;
}

final class CoreMediaLanguageSnapshot {
  const CoreMediaLanguageSnapshot({
    required this.authority,
    required this.preference,
  });

  factory CoreMediaLanguageSnapshot.fromJson(
    Object? raw, {
    required ServerContext context,
    required String accountId,
    required String sessionFamilyId,
  }) {
    final root = _object(raw, const {
      'schemaVersion',
      'authority',
      'preference',
    });
    if (root['schemaVersion'] is! int || root['schemaVersion'] != 1) {
      throw _invalid;
    }
    final authority = _object(root['authority'], const {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'sessionFamilyId',
      'accountRevision',
      'preferenceRevision',
    });
    final parsedContext = ServerContext.fromJson({
      'schemaVersion': authority['schemaVersion'],
      'coreId': authority['coreId'],
      'homeId': authority['homeId'],
    });
    final expectedFamily = _identity(sessionFamilyId);
    if (parsedContext != context ||
        _identity(authority['accountId']) != accountId ||
        _identity(authority['sessionFamilyId']) != expectedFamily) {
      throw _invalid;
    }
    final parsedAuthority = CoreMediaLanguageAuthority(
      context: parsedContext,
      accountId: accountId,
      sessionFamilyId: expectedFamily,
      accountRevision: _revision(authority['accountRevision']),
      preferenceRevision: _revision(
        authority['preferenceRevision'],
        empty: true,
      ),
    );
    if (root['preference'] == null) {
      if (parsedAuthority.preferenceRevision != 0) throw _invalid;
      return CoreMediaLanguageSnapshot(
        authority: parsedAuthority,
        preference: null,
      );
    }
    final preference = _object(root['preference'], const {
      'schemaVersion',
      'ref',
      'revision',
      'audioLanguage',
      'subtitleLanguage',
    });
    final ref = _object(preference['ref'], const {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'kind',
    });
    if (preference['schemaVersion'] is! int ||
        preference['schemaVersion'] != 1 ||
        ref['schemaVersion'] is! int ||
        ref['schemaVersion'] != 1 ||
        ref['coreId'] != context.coreId ||
        ref['homeId'] != context.homeId ||
        _identity(ref['accountId']) != accountId ||
        ref['kind'] != 'media_language_preferences') {
      throw _invalid;
    }
    final revision = _revision(preference['revision']);
    final audio = coreMediaLanguage(preference['audioLanguage']);
    final subtitle = coreMediaLanguage(
      preference['subtitleLanguage'],
      allowOff: true,
    );
    if (revision != parsedAuthority.preferenceRevision ||
        audio == null && subtitle == null) {
      throw _invalid;
    }
    return CoreMediaLanguageSnapshot(
      authority: parsedAuthority,
      preference: CoreMediaLanguagePreference(
        revision: revision,
        audioLanguage: audio,
        subtitleLanguage: subtitle,
      ),
    );
  }

  final CoreMediaLanguageAuthority authority;
  final CoreMediaLanguagePreference? preference;
}

String? coreMediaLanguage(Object? value, {bool allowOff = false}) {
  if (value == null) return null;
  if (value is! String) throw _invalid;
  if (allowOff && value == 'off') return value;
  if (!RegExp(r'^[a-z]{2,3}(?:-[a-z]{2}|-[0-9]{3})?$').hasMatch(value)) {
    throw _invalid;
  }
  return value;
}

Map<String, dynamic> _object(Object? raw, Set<String> keys) {
  final value = serverObject(raw);
  if (value.length != keys.length || !value.keys.every(keys.contains)) {
    throw _invalid;
  }
  return value;
}

String _identity(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    throw _invalid;
  }
  return value;
}

int _revision(Object? value, {bool empty = false}) {
  if (value is! int || value < (empty ? 0 : 1) || value > 0x7fffffffffffffff) {
    throw _invalid;
  }
  return value;
}

const _invalid = LarenorServerException('invalid_response');
