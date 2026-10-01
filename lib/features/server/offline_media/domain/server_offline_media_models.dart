import '../../domain/server_models.dart';

Never _invalid() => throw const FormatException('invalid_response');

final class ServerOfflineMediaScope {
  const ServerOfflineMediaScope({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamilyId,
  });

  factory ServerOfflineMediaScope.fromSession(ServerSession session) {
    final context = session.context;
    final family = session.sessionFamilyId;
    if (context == null || family == null) _invalid();
    return ServerOfflineMediaScope(
      coreId: context.coreId,
      homeId: context.homeId,
      accountId: session.user.id,
      sessionFamilyId: family,
    );
  }

  final String coreId, homeId, accountId, sessionFamilyId;

  bool matches(ServerOfflineMediaManifest manifest) =>
      manifest.coreId == coreId &&
      manifest.homeId == homeId &&
      manifest.accountId == accountId &&
      manifest.sessionFamilyId == sessionFamilyId;

  bool sameAuthority(ServerOfflineMediaScope other) =>
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      sessionFamilyId == other.sessionFamilyId;

  @override
  String toString() => 'ServerOfflineMediaScope(redacted)';
}

final class ServerOfflineMediaManifest {
  const ServerOfflineMediaManifest._({
    required this.grantId,
    required this.revision,
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.accountRevision,
    required this.sessionFamilyId,
    required this.installationId,
    required this.installationRevision,
    required this.snapshotRevision,
    required this.jellyfinServiceRevision,
    required this.itemId,
    required this.mediaKey,
    required this.title,
    required this.contentLength,
    required this.contentSha256,
    required this.contentType,
    required this.chunkBytes,
    required this.downloadedBytes,
    required this.state,
    required this.expiresAt,
  });

  factory ServerOfflineMediaManifest.fromJson(
    Object? value, {
    required ServerSession session,
  }) {
    final parsed = ServerOfflineMediaManifest.fromStorageJson(value);
    if (!ServerOfflineMediaScope.fromSession(session).matches(parsed)) {
      _invalid();
    }
    return parsed;
  }

  factory ServerOfflineMediaManifest.fromStorageJson(Object? value) {
    final map = serverObject(value);
    const keys = {
      'schemaVersion',
      'grantId',
      'revision',
      'authority',
      'title',
      'contentLength',
      'contentSha256',
      'contentType',
      'chunkBytes',
      'downloadedBytes',
      'state',
      'expiresAt',
    };
    if (map.length != keys.length ||
        !map.keys.every(keys.contains) ||
        map['schemaVersion'] != 1) {
      _invalid();
    }
    final authority = serverObject(map['authority']);
    const authorityKeys = {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'accountRevision',
      'sessionFamilyId',
      'installationId',
      'installationRevision',
      'snapshotRevision',
      'jellyfinServiceRevision',
      'itemId',
      'mediaKey',
    };
    if (authority.length != authorityKeys.length ||
        !authority.keys.every(authorityKeys.contains) ||
        authority['schemaVersion'] != 1) {
      _invalid();
    }
    String id(Object? value) {
      if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
        _invalid();
      }
      return value;
    }

    int revision(Object? value) {
      if (value is! int || value < 1 || value > 0x7ffffffffffffffe) _invalid();
      return value;
    }

    int bounded(Object? value, {required int minimum, required int maximum}) {
      if (value is! int || value < minimum || value > maximum) _invalid();
      return value;
    }

    String text(Object? value, int maximum) {
      if (value is! String ||
          value.isEmpty ||
          value.length > maximum ||
          value != value.trim() ||
          value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        _invalid();
      }
      return value;
    }

    final length = bounded(
      map['contentLength'],
      minimum: 1,
      maximum: 0x7fffffffffffffff,
    );
    final downloaded = bounded(
      map['downloadedBytes'],
      minimum: 0,
      maximum: length,
    );
    final state = map['state'];
    final accountRevision = revision(authority['accountRevision']);
    if (!{'granted', 'transferring', 'complete', 'revoked'}.contains(state) ||
        (state == 'complete') != (downloaded == length) && state != 'revoked') {
      _invalid();
    }
    final digest = map['contentSha256'];
    final expires = map['expiresAt'];
    if (digest is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        expires is! int ||
        expires < 1 ||
        expires > 253402300799) {
      _invalid();
    }
    return ServerOfflineMediaManifest._(
      grantId: id(map['grantId']),
      revision: revision(map['revision']),
      coreId: id(authority['coreId']),
      homeId: id(authority['homeId']),
      accountId: id(authority['accountId']),
      accountRevision: accountRevision,
      sessionFamilyId: id(authority['sessionFamilyId']),
      installationId: id(authority['installationId']),
      installationRevision: revision(authority['installationRevision']),
      snapshotRevision: revision(authority['snapshotRevision']),
      jellyfinServiceRevision: revision(authority['jellyfinServiceRevision']),
      itemId: id(authority['itemId']),
      mediaKey: text(authority['mediaKey'], 96),
      title: text(map['title'], 240),
      contentLength: length,
      contentSha256: digest,
      contentType: text(map['contentType'], 128),
      chunkBytes: bounded(
        map['chunkBytes'],
        minimum: 16384,
        maximum: 1024 * 1024,
      ),
      downloadedBytes: downloaded,
      state: state as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        expires * 1000,
        isUtc: true,
      ),
    );
  }

  final String grantId, coreId, homeId, accountId, sessionFamilyId;
  final String installationId,
      itemId,
      mediaKey,
      title,
      contentSha256,
      contentType;
  final int revision, accountRevision, installationRevision, snapshotRevision;
  final int jellyfinServiceRevision, contentLength, chunkBytes, downloadedBytes;
  final String state;
  final DateTime expiresAt;
  bool get complete => state == 'complete';

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'grantId': grantId,
    'revision': revision,
    'authority': {
      'schemaVersion': 1,
      'coreId': coreId,
      'homeId': homeId,
      'accountId': accountId,
      'accountRevision': accountRevision,
      'sessionFamilyId': sessionFamilyId,
      'installationId': installationId,
      'installationRevision': installationRevision,
      'snapshotRevision': snapshotRevision,
      'jellyfinServiceRevision': jellyfinServiceRevision,
      'itemId': itemId,
      'mediaKey': mediaKey,
    },
    'title': title,
    'contentLength': contentLength,
    'contentSha256': contentSha256,
    'contentType': contentType,
    'chunkBytes': chunkBytes,
    'downloadedBytes': downloadedBytes,
    'state': state,
    'expiresAt': expiresAt.millisecondsSinceEpoch ~/ 1000,
  };
}
