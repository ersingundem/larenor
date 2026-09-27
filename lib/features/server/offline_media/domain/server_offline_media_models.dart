import '../../domain/server_models.dart';

Never _invalid() => throw const FormatException('invalid_response');

final class ServerOfflineMediaManifest {
  const ServerOfflineMediaManifest._({
    required this.grantId,
    required this.revision,
    required this.coreId,
    required this.homeId,
    required this.accountId,
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
    final context = session.context;
    final family = session.sessionFamilyId;
    if (authority.length != authorityKeys.length ||
        !authority.keys.every(authorityKeys.contains) ||
        authority['schemaVersion'] != 1 ||
        context == null ||
        family == null ||
        authority['coreId'] != context.coreId ||
        authority['homeId'] != context.homeId ||
        authority['accountId'] != session.user.id ||
        authority['sessionFamilyId'] != family) {
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
    revision(authority['accountRevision']);
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
  final int revision, installationRevision, snapshotRevision;
  final int jellyfinServiceRevision, contentLength, chunkBytes, downloadedBytes;
  final String state;
  final DateTime expiresAt;
  bool get complete => state == 'complete';
}
