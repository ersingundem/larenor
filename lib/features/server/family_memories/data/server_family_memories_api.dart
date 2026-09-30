import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_family_memory_models.dart';

final class ServerFamilyMemoriesApi {
  const ServerFamilyMemoriesApi(this.api, this.token);

  final LarenorServerApi api;
  final String token;
  static const _root = '/family-memories';

  Future<FamilyMemorySourceState> sources({String? accountId}) =>
      _source('POST', {'accountId': accountId});

  Future<FamilyMemorySourceState> grantSource(
    FamilyMemorySourceState state,
    FamilyMemorySourceService service,
    List<String> albumIds,
  ) => _source('PUT', {
    'accountId': state.accountId,
    'expectedAccountRevision': state.accountRevision,
    'expectedRevision': state.revision,
    'serviceId': service.serviceId,
    'expectedServiceRevision': service.serviceRevision,
    'allowedAlbumIds': albumIds,
  });

  Future<FamilyMemorySourceState> revokeSource(FamilyMemorySourceState state) =>
      _source('DELETE', {
        'accountId': state.accountId,
        'expectedAccountRevision': state.accountRevision,
        'expectedRevision': state.revision,
      });

  Future<FamilyMemorySourceState> faceConsent(
    FamilyMemorySourceState state,
    bool enabled,
  ) => _source('PUT', {
    'expectedRevision': state.revision,
    'enabled': enabled,
  }, path: '$_root/sources/face-consent');

  Future<FamilyMemorySourceState> _source(
    String method,
    Map<String, Object?> body, {
    String path = '$_root/sources',
  }) async {
    final id = requestId();
    return FamilyMemorySourceState.fromJson(
      _envelope(
        await api.request(
          method,
          path,
          token: token,
          body: {'schemaVersion': 1, 'requestId': id, ...body},
        ),
        id,
        'source',
      ),
    );
  }

  Future<List<FamilyMemorySourceAlbum>> sourceAlbums(
    FamilyMemorySourceService service,
  ) async {
    final id = requestId();
    final json = serverObject(
      await api.request(
        'POST',
        '$_root/sources/albums',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestId': id,
          'serviceId': service.serviceId,
          'expectedServiceRevision': service.serviceRevision,
        },
      ),
    );
    if (json.length != 2 ||
        json['requestId'] != id ||
        json['albums'] is! List) {
      throw const LarenorServerException('invalid_response');
    }
    final albums = (json['albums'] as List)
        .map(FamilyMemorySourceAlbum.fromJson)
        .toList();
    if (albums.length > 512 ||
        albums.map((e) => e.albumId).toSet().length != albums.length) {
      throw const LarenorServerException('invalid_response');
    }
    return List.unmodifiable(albums);
  }

  static String requestId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<FamilyMemorySnapshot> snapshot() async {
    final id = requestId();
    final json = _envelope(
      await api.request(
        'POST',
        '$_root/snapshot',
        token: token,
        body: {'schemaVersion': 1, 'requestId': id},
      ),
      id,
      'snapshot',
    );
    return FamilyMemorySnapshot.fromJson(json);
  }

  Future<List<FamilyMemoryAsset>> search({
    required FamilyMemoryAuthority authority,
    required String serviceId,
    required int serviceRevision,
    required String query,
    required List<String> albumIds,
    List<String> personIds = const [],
    String language = 'tr',
    String? takenAfter,
    String? takenBefore,
    int limit = 48,
  }) async {
    final id = requestId();
    final json = serverObject(
      await api.request(
        'POST',
        '$_root/search',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestId': id,
          'expectedMembersRevision': authority.membersRevision,
          'serviceId': serviceId,
          'expectedServiceRevision': serviceRevision,
          'query': query,
          'albumIds': albumIds,
          'limit': limit,
          'language': language,
          'personIds': personIds,
          'takenAfter': takenAfter,
          'takenBefore': takenBefore,
        },
      ),
    );
    if (json.length != 2 ||
        json['requestId'] != id ||
        json['assets'] is! List) {
      throw const LarenorServerException('invalid_response');
    }
    final assets = (json['assets'] as List)
        .map(FamilyMemoryAsset.fromJson)
        .toList();
    if (assets.length > limit ||
        assets.map((e) => e.assetId).toSet().length != assets.length) {
      throw const LarenorServerException('invalid_response');
    }
    return List.unmodifiable(assets);
  }

  Future<FamilyMemoryAlbum> create({
    required FamilyMemoryAuthority authority,
    required String title,
    required String visibility,
    required List<String> memberIds,
    required String serviceId,
    required int serviceRevision,
  }) async {
    final id = requestId();
    return _album(
      api.request(
        'POST',
        '$_root/albums',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestId': id,
          'expectedMembersRevision': authority.membersRevision,
          'title': title,
          'visibility': visibility,
          'memberIds': memberIds,
          'serviceId': serviceId,
          'expectedServiceRevision': serviceRevision,
        },
      ),
      id,
    );
  }

  Future<FamilyMemoryAlbum> replaceAssets(
    FamilyMemoryAuthority authority,
    FamilyMemoryAlbum album,
    List<FamilyMemorySelection> assets,
  ) async {
    final id = requestId();
    return _album(
      api.request(
        'PUT',
        '$_root/albums/${album.albumId}/assets',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestId': id,
          'expectedMembersRevision': authority.membersRevision,
          'expectedRevision': album.revision,
          'serviceId': album.serviceId,
          'expectedServiceRevision': album.serviceRevision,
          'assets': assets.map((item) => item.toJson()).toList(),
        },
      ),
      id,
    );
  }

  Future<FamilyMemoryAlbum> update({
    required FamilyMemoryAuthority authority,
    required FamilyMemoryAlbum album,
    required String title,
    required String visibility,
    required List<String> memberIds,
  }) async {
    final id = requestId();
    return _album(
      api.request(
        'PUT',
        '$_root/albums/${album.albumId}',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestId': id,
          'expectedMembersRevision': authority.membersRevision,
          'expectedRevision': album.revision,
          'title': title,
          'visibility': visibility,
          'memberIds': memberIds,
        },
      ),
      id,
    );
  }

  Future<void> delete(
    FamilyMemoryAuthority authority,
    FamilyMemoryAlbum album,
  ) async {
    final id = requestId();
    final value = await api.request(
      'DELETE',
      '$_root/albums/${album.albumId}',
      token: token,
      body: {
        'schemaVersion': 1,
        'requestId': id,
        'expectedMembersRevision': authority.membersRevision,
        'expectedRevision': album.revision,
      },
    );
    if (value != null) {
      throw const LarenorServerException('invalid_response');
    }
  }

  Future<FamilyMemoryAlbum> reconcile(
    FamilyMemoryAuthority authority,
    FamilyMemoryAlbum album,
  ) async {
    final id = requestId();
    return _album(
      api.request(
        'POST',
        '$_root/albums/${album.albumId}/reconcile',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestId': id,
          'expectedMembersRevision': authority.membersRevision,
          'expectedRevision': album.revision,
          'serviceId': album.serviceId,
          'expectedServiceRevision': album.serviceRevision,
        },
      ),
      id,
    );
  }

  Future<FamilyMemoryAlbum> _album(Future<Object?> pending, String id) async =>
      FamilyMemoryAlbum.fromJson(_envelope(await pending, id, 'album'));

  static Object? _envelope(Object? value, String id, String key) {
    final json = serverObject(value);
    if (json.length != 2 || json['requestId'] != id || !json.containsKey(key)) {
      throw const LarenorServerException('invalid_response');
    }
    return json[key];
  }
}
