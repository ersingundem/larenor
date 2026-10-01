import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/offline_media/data/server_offline_media_vault.dart';
import 'package:larenor/features/server/offline_media/domain/server_offline_media_models.dart';

const _grantId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _coreId = '11111111111111111111111111111111';
const _homeId = '22222222222222222222222222222222';
const _accountId = '33333333333333333333333333333333';
const _familyId = '44444444444444444444444444444444';
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

ServerSession _session() {
  return ServerSession(
    endpoint: ServerEndpoint('https://core.invalid'),
    accessToken: 'synthetic_offline_access_token_1234567890',
    refreshToken: 'synthetic_offline_refresh_token_123456789',
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    user: const ServerUser(
      id: _accountId,
      username: 'traveler',
      role: ServerRole.member,
      mustChangePassword: false,
    ),
    sessionFamilyId: _familyId,
    context: ServerContext.fromJson(const {
      'schemaVersion': 1,
      'coreId': _coreId,
      'homeId': _homeId,
    }),
  );
}

ServerOfflineMediaManifest _manifest({
  String grantId = _grantId,
  Uint8List? clear,
}) {
  final bytes = clear ?? _clear;
  return ServerOfflineMediaManifest.fromJson({
    'schemaVersion': 1,
    'grantId': grantId,
    'revision': 3,
    'authority': {
      'schemaVersion': 1,
      'coreId': _coreId,
      'homeId': _homeId,
      'accountId': _accountId,
      'accountRevision': 4,
      'sessionFamilyId': _familyId,
      'installationId': '55555555555555555555555555555555',
      'installationRevision': 3,
      'snapshotRevision': 5,
      'jellyfinServiceRevision': 7,
      'itemId': '66666666666666666666666666666666',
      'mediaKey': 'movie:tmdb:603',
    },
    'title': 'The Matrix',
    'contentLength': bytes.length,
    'contentSha256': sha256.convert(bytes).toString(),
    'contentType': 'video/mp4',
    'chunkBytes': 16384,
    'downloadedBytes': bytes.length,
    'state': 'complete',
    'expiresAt':
        DateTime.now()
            .toUtc()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch ~/
        1000,
  }, session: _session());
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
      await vault.storeCompletedManifest(manifest);

      final chunkFile = File('${root.path}/$_grantId/0000000000000000.chunk');
      final encrypted = await chunkFile.readAsBytes();
      expect(encrypted.length, greaterThan(_clear.length));
      expect(_contains(encrypted, _clear), isFalse);
      expect(await vault.readChunks(_grantId), [_clear]);

      final manifestFile = File('${root.path}/$_grantId/completed.manifest.v1');
      final encryptedManifest = await manifestFile.readAsBytes();
      expect(_contains(encryptedManifest, _clear), isFalse);
      expect(_contains(encryptedManifest, 'The Matrix'.codeUnits), isFalse);
      expect(_contains(encryptedManifest, 'movie:tmdb:603'.codeUnits), isFalse);

      final restarted = ServerOfflineMediaVault(root: () async => root);
      final restored = await restarted.loadCompletedItem(
        ServerOfflineMediaScope.fromSession(_session()),
        manifest.itemId,
      );
      expect(restored?.toJson(), manifest.toJson());
      expect(restored?.accountRevision, 4);

      final lease = await restarted.openPlayback(restored!);
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
      await restarted.purgeScope(
        ServerOfflineMediaScope.fromSession(_session()),
      );
      expect(await Directory('${root.path}/$_grantId').exists(), isFalse);
      expect(
        await const FlutterSecureStorage().read(
          key: 'larenor.offline-media.v1.$_grantId',
        ),
        isNull,
      );
    },
  );

  test('cold recovery never creates a missing key or directory', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp(
      'larenor-offline-vault-existing-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final vault = ServerOfflineMediaVault(root: () async => root);
    final manifest = _manifest();
    await vault.writeChunk(_grantId, 0, _clear);
    await vault.storeCompletedManifest(manifest);
    await const FlutterSecureStorage().delete(
      key: 'larenor.offline-media.v1.$_grantId',
    );

    await expectLater(
      vault.loadCompletedItem(
        ServerOfflineMediaScope.fromSession(_session()),
        manifest.itemId,
      ),
      throwsFormatException,
    );
    expect(
      await const FlutterSecureStorage().read(
        key: 'larenor.offline-media.v1.$_grantId',
      ),
      isNull,
    );
    await Directory('${root.path}/$_grantId').delete(recursive: true);

    final absent = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    expect(await Directory('${root.path}/$absent').exists(), isFalse);
    expect(
      await vault.loadCompletedItem(
        ServerOfflineMediaScope.fromSession(_session()),
        absent,
      ),
      isNull,
    );
    expect(await Directory('${root.path}/$absent').exists(), isFalse);
  });

  test('tampered manifest and symlinked grant fail closed', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp(
      'larenor-offline-vault-tamper-',
    );
    final foreign = await Directory.systemTemp.createTemp(
      'larenor-offline-vault-foreign-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
      if (await foreign.exists()) await foreign.delete(recursive: true);
    });
    final vault = ServerOfflineMediaVault(root: () async => root);
    final manifest = _manifest();
    await vault.writeChunk(_grantId, 0, _clear);
    await vault.storeCompletedManifest(manifest);
    final stored = File('${root.path}/$_grantId/completed.manifest.v1');
    final raw = await stored.readAsBytes();
    raw[raw.length - 1] ^= 1;
    await stored.writeAsBytes(raw, flush: true);

    await expectLater(
      vault.loadCompletedItem(
        ServerOfflineMediaScope.fromSession(_session()),
        manifest.itemId,
      ),
      throwsA(anything),
    );

    await Directory('${root.path}/$_grantId').delete(recursive: true);
    await Link('${root.path}/$_grantId').create(foreign.path);
    await expectLater(
      vault.completed(ServerOfflineMediaScope.fromSession(_session())),
      throwsFormatException,
    );
    expect(await foreign.exists(), isTrue);
  });

  test('chunk reads never create a missing grant or key', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('larenor-vault-read-');
    addTearDown(() => root.delete(recursive: true));
    final vault = ServerOfflineMediaVault(root: () async => root);
    expect(await vault.readChunks(_grantId), isEmpty);
    expect(await root.list().toList(), isEmpty);
    expect(await const FlutterSecureStorage().readAll(), isEmpty);
  });

  test('a symlinked vault root cannot read or purge its target', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final parent = await Directory.systemTemp.createTemp('larenor-vault-link-');
    final foreign = Directory('${parent.path}/foreign');
    await foreign.create();
    addTearDown(() => parent.delete(recursive: true));
    final original = ServerOfflineMediaVault(root: () async => foreign);
    await original.writeChunk(_grantId, 0, _clear);
    await original.storeCompletedManifest(_manifest());
    final link = Link('${parent.path}/linked');
    await link.create(foreign.path);
    final linked = ServerOfflineMediaVault(
      root: () async => Directory(link.path),
    );
    await expectLater(
      linked.completed(ServerOfflineMediaScope.fromSession(_session())),
      throwsFormatException,
    );
    await expectLater(linked.purge(_grantId), throwsFormatException);
    expect(await Directory('${foreign.path}/$_grantId').exists(), isTrue);
    expect(await const FlutterSecureStorage().readAll(), isNotEmpty);
  });

  test('an active loopback read cannot replace a deleted secure key', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('larenor-vault-key-');
    addTearDown(() => root.delete(recursive: true));
    final vault = ServerOfflineMediaVault(root: () async => root);
    await vault.writeChunk(_grantId, 0, _clear);
    await vault.storeCompletedManifest(_manifest());
    final lease = await vault.openPlayback(_manifest());
    addTearDown(lease.close);
    await const FlutterSecureStorage().delete(
      key: 'larenor.offline-media.v1.$_grantId',
    );
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(lease.uri)).close();
    await response.drain<void>();
    expect(response.statusCode, HttpStatus.internalServerError);
    expect(await const FlutterSecureStorage().readAll(), isEmpty);
  });
}
