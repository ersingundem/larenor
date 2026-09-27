import '../../domain/server_models.dart';

Map<String, dynamic> _closed(Object? value, Set<String> keys) {
  final json = serverObject(value);
  if (json.length != keys.length || !json.keys.every(keys.contains)) {
    throw const LarenorServerException('invalid_response');
  }
  return json;
}

String _id(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

String _uuid(Object? value) {
  if (value is! String ||
      !RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(value)) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

final class FamilyMemoryAuthority {
  const FamilyMemoryAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionId,
    required this.membersRevision,
  });

  factory FamilyMemoryAuthority.fromJson(Object? value) {
    final json = _closed(value, const {
      'coreId',
      'homeId',
      'accountId',
      'sessionId',
      'membersRevision',
    });
    return FamilyMemoryAuthority(
      coreId: _id(json['coreId']),
      homeId: _id(json['homeId']),
      accountId: _id(json['accountId']),
      sessionId: _id(json['sessionId']),
      membersRevision: _revision(json['membersRevision']),
    );
  }

  final String coreId, homeId, accountId, sessionId;
  final int membersRevision;
}

final class FamilyMemoryBinding {
  const FamilyMemoryBinding({
    required this.serviceId,
    required this.serviceRevision,
    required this.allowedAlbumIds,
    required this.faceSearchEnabled,
  });

  factory FamilyMemoryBinding.fromJson(Object? value) {
    final json = _closed(value, const {
      'serviceId',
      'serviceRevision',
      'allowedAlbumIds',
      'faceSearchEnabled',
    });
    final raw = json['allowedAlbumIds'];
    if (raw is! List ||
        raw.isEmpty ||
        raw.length > 32 ||
        json['faceSearchEnabled'] is! bool) {
      throw const LarenorServerException('invalid_response');
    }
    final albums = raw.map(_uuid).toList(growable: false);
    if (albums.toSet().length != albums.length) {
      throw const LarenorServerException('invalid_response');
    }
    return FamilyMemoryBinding(
      serviceId: _id(json['serviceId']),
      serviceRevision: _revision(json['serviceRevision']),
      allowedAlbumIds: List.unmodifiable(albums),
      faceSearchEnabled: json['faceSearchEnabled'] as bool,
    );
  }

  final String serviceId;
  final int serviceRevision;
  final List<String> allowedAlbumIds;
  final bool faceSearchEnabled;
}

final class FamilyMemorySelection {
  const FamilyMemorySelection(
    this.assetId,
    this.sourceAlbumId,
    this.sourceEtag,
  );

  factory FamilyMemorySelection.fromJson(Object? value) {
    final json = _closed(value, const {
      'assetId',
      'sourceAlbumId',
      'sourceEtag',
    });
    final etag = json['sourceEtag'];
    if (etag is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(etag)) {
      throw const LarenorServerException('invalid_response');
    }
    return FamilyMemorySelection(
      _uuid(json['assetId']),
      _uuid(json['sourceAlbumId']),
      etag,
    );
  }

  final String assetId, sourceAlbumId, sourceEtag;

  Map<String, Object> toJson() => {
    'assetId': assetId,
    'sourceAlbumId': sourceAlbumId,
    'sourceEtag': sourceEtag,
  };
}

final class FamilyMemoryAsset {
  const FamilyMemoryAsset({
    required this.assetId,
    required this.fileName,
    required this.takenAt,
    required this.thumbhash,
    required this.sourceEtag,
    required this.sourceAlbumId,
  });

  factory FamilyMemoryAsset.fromJson(Object? value) {
    final json = _closed(value, const {
      'assetId',
      'fileName',
      'takenAt',
      'thumbhash',
      'sourceEtag',
      'sourceAlbumId',
    });
    final thumbhash = json['thumbhash'];
    final etag = json['sourceEtag'];
    if (thumbhash != null &&
            (thumbhash is! String || thumbhash.length > 1024) ||
        etag is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(etag)) {
      throw const LarenorServerException('invalid_response');
    }
    return FamilyMemoryAsset(
      assetId: _uuid(json['assetId']),
      fileName: serverText(json['fileName'], max: 512),
      takenAt: serverText(json['takenAt'], max: 40),
      thumbhash: thumbhash as String?,
      sourceEtag: etag,
      sourceAlbumId: _uuid(json['sourceAlbumId']),
    );
  }

  final String assetId, fileName, takenAt, sourceEtag, sourceAlbumId;
  final String? thumbhash;
}

final class FamilyMemoryAlbum {
  const FamilyMemoryAlbum({
    required this.albumId,
    required this.revision,
    required this.title,
    required this.visibility,
    required this.ownerId,
    required this.memberIds,
    required this.serviceId,
    required this.serviceRevision,
    required this.assets,
    required this.updatedAt,
  });

  factory FamilyMemoryAlbum.fromJson(Object? value) {
    final json = _closed(value, const {
      'albumId',
      'revision',
      'title',
      'visibility',
      'ownerId',
      'memberIds',
      'serviceId',
      'serviceRevision',
      'assets',
      'updatedAt',
    });
    final visibility = json['visibility'];
    final rawMembers = json['memberIds'];
    final rawAssets = json['assets'];
    final updated = json['updatedAt'];
    if (!{'personal', 'shared'}.contains(visibility) ||
        rawMembers is! List ||
        rawMembers.isEmpty ||
        rawMembers.length > 32 ||
        rawAssets is! List ||
        rawAssets.length > 250 ||
        updated is! num ||
        !updated.isFinite ||
        updated < 0) {
      throw const LarenorServerException('invalid_response');
    }
    final owner = _id(json['ownerId']);
    final members = rawMembers.map(_id).toList(growable: false);
    final assets = rawAssets
        .map(FamilyMemorySelection.fromJson)
        .toList(growable: false);
    if (members.toSet().length != members.length ||
        !members.contains(owner) ||
        visibility == 'personal' &&
            (members.length != 1 || members.first != owner) ||
        assets.map((item) => item.assetId).toSet().length != assets.length) {
      throw const LarenorServerException('invalid_response');
    }
    return FamilyMemoryAlbum(
      albumId: _id(json['albumId']),
      revision: _revision(json['revision']),
      title: serverText(json['title'], max: 120),
      visibility: visibility as String,
      ownerId: owner,
      memberIds: List.unmodifiable(members),
      serviceId: _id(json['serviceId']),
      serviceRevision: _revision(json['serviceRevision']),
      assets: List.unmodifiable(assets),
      updatedAt: updated.toDouble(),
    );
  }

  final String albumId, title, visibility, ownerId, serviceId;
  final int revision, serviceRevision;
  final List<String> memberIds;
  final List<FamilyMemorySelection> assets;
  final double updatedAt;
}

final class FamilyMemorySnapshot {
  const FamilyMemorySnapshot(
    this.authority,
    this.binding,
    this.memberIds,
    this.albums,
  );

  factory FamilyMemorySnapshot.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'authority',
      'binding',
      'memberIds',
      'albums',
    });
    final raw = json['albums'];
    final rawMembers = json['memberIds'];
    if (json['schemaVersion'] != 1 ||
        raw is! List ||
        raw.length > 64 ||
        rawMembers is! List ||
        rawMembers.isEmpty ||
        rawMembers.length > 32) {
      throw const LarenorServerException('invalid_response');
    }
    final albums = raw.map(FamilyMemoryAlbum.fromJson).toList(growable: false);
    final members = rawMembers.map(_id).toList(growable: false);
    if (albums.map((item) => item.albumId).toSet().length != albums.length ||
        members.toSet().length != members.length) {
      throw const LarenorServerException('invalid_response');
    }
    return FamilyMemorySnapshot(
      FamilyMemoryAuthority.fromJson(json['authority']),
      FamilyMemoryBinding.fromJson(json['binding']),
      List.unmodifiable(members),
      List.unmodifiable(albums),
    );
  }

  final FamilyMemoryAuthority authority;
  final FamilyMemoryBinding binding;
  final List<String> memberIds;
  final List<FamilyMemoryAlbum> albums;
}
