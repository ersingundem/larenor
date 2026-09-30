import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/offline_media/data/server_offline_media_vault.dart';
import 'package:larenor/features/server/offline_media/domain/server_offline_media_models.dart';

const _grantId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final _clear = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

bool _contains(List<int> source, List<int> pattern) {
  for (var start = 0; start <= source.length - pattern.length; start++) {
    var matches = true;
    for (var index = 0; index < pattern.length; index++) {
      if (source[start + index] != pattern[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

ServerOfflineMediaManifest _manifest() {
  const coreId = '11111111111111111111111111111111';
  const homeId = '22222222222222222222222222222222';
  const accountId = '33333333333333333333333333333333';
  const familyId = '44444444444444444444444444444444';
  final session = ServerSession(
    endpoint: ServerEndpoint('https://core.invalid'),
    accessToken: 'synthetic_offline_access_token_1234567890',
    refreshToken: 'synthetic_offline_refresh_token_123456789',
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    user: const ServerUser(
      id: accountId,
      username: 'traveler',
      role: ServerRole.member,
      mustChangePassword: false,
    ),
    sessionFamilyId: familyId,
    context: ServerContext.fromJson(const {
      'schemaVersion': 1,
      'coreId': coreId,
      'homeId': homeId,
    }),
  );
  return ServerOfflineMediaManifest.fromJson({
    'schemaVersion': 1,
    'grantId': _grantId,
    'revision': 3,
    'authority': {
      'schemaVersion': 1,
      'coreId': coreId,
      'homeId': homeId,
      'accountId': accountId,
      'accountRevision': 4,
      'sessionFamilyId': familyId,
      'installationId': '55555555555555555555555555555555',
      'installationRevision': 3,
      'snapshotRevision': 5,
      'jellyfinServiceRevision': 7,
      'itemId': '66666666666666666666666666666666',
      'mediaKey': 'movie:tmdb:603',
    },
    'title': 'The Matrix',
    'contentLength': _clear.length,
    'contentSha256': sha256.convert(_clear).toString(),
    'contentType': 'video/mp4',
    'chunkBytes': 16384,
    'downloadedBytes': _clear.length,
    'state': 'complete',
    'expiresAt':
        DateTime.now()
            .toUtc()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch ~/
        1000,
  }, session: session);
}

void main() {
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = null);

  test(
    'encrypted vault serves only bounded plaintext over loopback lease',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp(
        'larenor-offline-vault-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final vault = ServerOfflineMediaVault(root: () async => root);
      final manifest = _manifest();

      await vault.writeChunk(_grantId, 0, _clear);

      final chunkFile = File('${root.path}/$_grantId/0000000000000000.chunk');
      final encrypted = await chunkFile.readAsBytes();
      expect(encrypted.length, greaterThan(_clear.length));
      expect(_contains(encrypted, _clear), isFalse);
      expect(await vault.readChunks(_grantId), [_clear]);

      final lease = await vault.openPlayback(manifest);
      addTearDown(lease.close);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(lease.uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=2-5');
      final response = await request.close();
      final bytes = await response.fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );

      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 2-5/8',
      );
      expect(
        response.headers.value(HttpHeaders.cacheControlHeader),
        'no-store',
      );
      expect(bytes, [3, 4, 5, 6]);

      await lease.close();
      await vault.purge(_grantId);
      expect(await Directory('${root.path}/$_grantId').exists(), isFalse);
      expect(
        await const FlutterSecureStorage().read(
          key: 'larenor.offline-media.v1.$_grantId',
        ),
        isNull,
      );
    },
  );
}
