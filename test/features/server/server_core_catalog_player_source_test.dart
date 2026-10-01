import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/local_media_player/data/core_catalog_playback_capability_adapter.dart';
import 'package:larenor/features/server/local_media_player/data/core_catalog_player_source.dart';
import 'package:larenor/features/server/local_media_player/domain/core_catalog_player_binding.dart';
import 'package:larenor/features/server/media_catalog/domain/server_media_catalog_models.dart';
import 'package:larenor/features/server/offline_media/data/server_offline_media_controller.dart';
import 'package:larenor/features/server/offline_media/data/server_offline_media_vault.dart';
import 'package:larenor/features/server/offline_media/domain/server_offline_media_models.dart';

import 'server_admin_test_support.dart';

const _installation = '11111111111111111111111111111111';
const _item = '22222222222222222222222222222222';

final class _Port implements CoreCatalogPlaybackCapabilityPort {
  Object? value = _native();
  var reads = 0;

  @override
  Future<Object?> snapshot() async {
    reads++;
    return value;
  }
}

Map<String, Object?> _native({int networkRevision = 13}) => {
  'schemaVersion': 1,
  'displayWidthPixels': 2560,
  'displayHeightPixels': 1440,
  'displayRevision': 11,
  'decoderMimeTypes': [
    'audio/eac3',
    'audio/mp4a-latm',
    'video/avc',
    'video/hevc',
  ],
  'decoderMimeTypesTruncated': false,
  'decoderRevision': 12,
  'networkTransports': ['wifi'],
  'networkValidated': true,
  'networkMetered': false,
  'networkDownstreamKbps': 80000,
  'networkRevision': networkRevision,
};

CoreCatalogPlayerBinding _binding() {
  final page = ServerMediaCatalogPage.fromJson(
    {
      'schemaVersion': 1,
      'installationId': _installation,
      'installationRevision': 5,
      'snapshotRevision': 7,
      'jellyfinServiceRevision': 9,
      'offset': 0,
      'nextOffset': null,
      'total': 1,
      'items': [
        {
          'itemId': _item,
          'mediaKey': 'movie:tmdb:603',
          'title': 'The Matrix',
          'mediaKind': 'movie',
          'runtimeSeconds': 8160,
        },
      ],
    },
    operation: ServerMediaCatalogOperation.browse,
    mediaKind: null,
  );
  return CoreCatalogPlayerBinding.fromCatalog(page, page.items.single);
}

Map<String, Object?> _observation(
  CoreCatalogLocalPlaybackProfile profile,
  DateTime now,
  String observationId,
) => {
  'schemaVersion': 1,
  'requestId': '3' * 32,
  'observationId': observationId,
  'authority': {
    'schemaVersion': 1,
    'coreId': 'a' * 32,
    'homeId': 'b' * 32,
    'accountId': adminId,
    'accountRevision': 1,
    'sessionFamilyId': sessionFamilyId,
    'installationId': _installation,
    'installationRevision': 5,
    'snapshotRevision': 7,
    'jellyfinServiceRevision': 9,
    'itemId': _item,
    'mediaKey': 'movie:tmdb:603',
    'profileId': profile.profileId,
    'profileRevision': profile.profileRevision,
    'displayRevision': profile.displayRevision,
    'decoderRevision': profile.decoderRevision,
    'networkRevision': profile.networkRevision,
    'policyRevision': profile.policyRevision,
    'profileDigest': profile.digest,
  },
  'observation': {
    'schemaVersion': 1,
    'assurance': 'provider_observed_for_client_reported_profile',
    'originalByteOutcome': 'direct_play_supported',
    'playMethod': 'direct_play',
    'source': {
      'container': 'mp4',
      'bitrateBps': 12000000,
      'videoCodecs': ['h264'],
      'audioCodecs': ['aac'],
      'videoRanges': ['SDR'],
    },
    'transcoding': null,
    'reason': 'available',
    'advisoryOnly': true,
    'physicalAcceptance': 'manual',
    'observedAt': now.millisecondsSinceEpoch ~/ 1000,
    'expiresAt': now.millisecondsSinceEpoch ~/ 1000 + 30,
  },
};

Map<String, Object?> _lease(
  String leaseId,
  DateTime expiresAt, {
  int revision = 1,
  String state = 'active',
}) => {
  'lease': {
    'schemaVersion': 1,
    'leaseId': leaseId,
    'revision': revision,
    'authority': {
      'schemaVersion': 1,
      'coreId': 'a' * 32,
      'homeId': 'b' * 32,
      'accountId': adminId,
      'accountRevision': 1,
      'sessionFamilyId': sessionFamilyId,
      'installationId': _installation,
      'installationRevision': 5,
      'snapshotRevision': 7,
      'jellyfinServiceRevision': 9,
      'itemId': _item,
      'mediaKey': 'movie:tmdb:603',
    },
    'title': 'The Matrix',
    'mediaKind': 'movie',
    'runtimeSeconds': 8160,
    'contentLength': 4096,
    'contentType': 'application/octet-stream',
    'byteIntegrity': 'source_bound',
    'supportsByteRanges': true,
    'state': state,
    'expiresAt': expiresAt.millisecondsSinceEpoch ~/ 1000,
    'restartBehavior': 'terminal_invalid',
  },
};

ServerOfflineMediaManifest _offlineManifest(
  AdminFixture fixture,
  String grantId,
  Uint8List bytes,
) => ServerOfflineMediaManifest.fromJson({
  'schemaVersion': 1,
  'grantId': grantId,
  'revision': 2,
  'authority': {
    'schemaVersion': 1,
    'coreId': 'a' * 32,
    'homeId': 'b' * 32,
    'accountId': adminId,
    'accountRevision': 1,
    'sessionFamilyId': sessionFamilyId,
    'installationId': _installation,
    'installationRevision': 5,
    'snapshotRevision': 7,
    'jellyfinServiceRevision': 9,
    'itemId': _item,
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
}, session: fixture.account.session!);

final class _AuthorizedFixture {
  _AuthorizedFixture(this.fixture, this.port, this.adapter, this.profile);

  final AdminFixture fixture;
  final _Port port;
  final CoreCatalogPlaybackCapabilityAdapter adapter;
  final CoreCatalogLocalPlaybackProfile profile;

  Future<CoreCatalogPlaybackAuthorization> authorize(String id) async {
    fixture.respond = (request) async {
      expect(request.url.path, contains('/media/playback-quality/'));
      return fixture.json(_observation(profile, fixture.now, id));
    };
    return (await adapter.observe(_binding(), current: () => true))!;
  }
}

Future<_AuthorizedFixture> _authorizedFixture() async {
  final fixture = AdminFixture();
  await fixture.account.initialize();
  final port = _Port();
  final adapter = CoreCatalogPlaybackCapabilityAdapter(
    fixture.account,
    port: port,
    requestId: () => '3' * 32,
    clock: () => fixture.now,
  );
  final profile = (await adapter.capture())!;
  return _AuthorizedFixture(fixture, port, adapter, profile);
}

void main() {
  test(
    'verified Core offers the online route behind exact observation admission',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(coreCatalogOnlinePlaybackAvailableProvider),
        isTrue,
      );
    },
  );

  test(
    'online lease requires observation and rejects an expired schedule',
    () async {
      final harness = await _authorizedFixture();
      addTearDown(harness.fixture.account.dispose);
      final source = CoreLeaseCatalogPlayerSource(
        harness.fixture.account,
        capability: harness.adapter,
        clock: () => harness.fixture.now,
      );
      addTearDown(source.dispose);
      final binding = _binding();

      expect(
        await source.open(
          binding,
          mode: CoreCatalogPlayerSourceMode.coreLease,
          authorization: null,
          current: () => true,
        ),
        isNull,
      );
      final authorization = await harness.authorize('4' * 32);
      var creates = 0;
      var retires = 0;
      harness.fixture.respond = (request) async {
        if (request.url.path.endsWith('/playback-leases')) {
          creates++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['playbackObservationId'], '4' * 32);
          return harness.fixture.json(
            _lease(
              body['requestId']! as String,
              harness.fixture.now.subtract(const Duration(seconds: 1)),
            ),
          );
        }
        if (request.url.path.endsWith('/retire')) {
          retires++;
          return harness.fixture.json(
            _lease('5' * 32, harness.fixture.now, state: 'retired'),
          );
        }
        return harness.fixture.defaultResponse(request);
      };

      expect(
        await source.open(
          binding,
          mode: CoreCatalogPlayerSourceMode.coreLease,
          authorization: authorization,
          current: () => true,
        ),
        isNull,
      );
      expect(creates, 1);
      expect(retires, 1);
    },
  );

  test(
    'late overlapping create is retired without closing its successor',
    () async {
      final harness = await _authorizedFixture();
      addTearDown(harness.fixture.account.dispose);
      final source = CoreLeaseCatalogPlayerSource(
        harness.fixture.account,
        capability: harness.adapter,
        clock: () => harness.fixture.now,
      );
      addTearDown(source.dispose);
      final firstAuthorization = await harness.authorize('4' * 32);
      final secondAuthorization = await harness.authorize('6' * 32);
      final firstResponse = Completer<http.Response>();
      final firstStarted = Completer<void>();
      var creates = 0;
      final created = <String>[];
      final retired = <String>[];
      harness.fixture.respond = (request) async {
        if (request.url.path.endsWith('/playback-leases')) {
          creates++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final leaseId = body['requestId']! as String;
          created.add(leaseId);
          if (creates == 1) {
            firstStarted.complete();
            return firstResponse.future;
          }
          return harness.fixture.json(
            _lease(
              leaseId,
              harness.fixture.now.add(const Duration(minutes: 2)),
            ),
          );
        }
        if (request.url.path.endsWith('/retire')) {
          retired.add(
            request.url.pathSegments[request.url.pathSegments.length - 2],
          );
          return harness.fixture.json(
            _lease(
              request.url.pathSegments[request.url.pathSegments.length - 2],
              harness.fixture.now,
              state: 'retired',
            ),
          );
        }
        return harness.fixture.defaultResponse(request);
      };
      final first = source.open(
        _binding(),
        mode: CoreCatalogPlayerSourceMode.coreLease,
        authorization: firstAuthorization,
        current: () => true,
      );
      await firstStarted.future;
      final successor = await source.open(
        _binding(),
        mode: CoreCatalogPlayerSourceMode.coreLease,
        authorization: secondAuthorization,
        current: () => true,
      );
      expect(successor, isNotNull);
      firstResponse.complete(
        harness.fixture.json(
          _lease(
            created.first,
            harness.fixture.now.add(const Duration(minutes: 2)),
          ),
        ),
      );

      expect(await first, isNull);
      expect(retired, [created.first]);
      await successor!.close();
      expect(retired, created);
    },
  );

  test('create binds lease id and revision to its exact request', () async {
    final harness = await _authorizedFixture();
    addTearDown(harness.fixture.account.dispose);
    final source = CoreLeaseCatalogPlayerSource(
      harness.fixture.account,
      capability: harness.adapter,
      random: Random(7),
      clock: () => harness.fixture.now,
    );
    addTearDown(source.dispose);
    final retired = <({String id, int revision})>[];
    for (var scenario = 0; scenario < 2; scenario++) {
      final authorization = await harness.authorize(
        scenario == 0 ? '4' * 32 : '6' * 32,
      );
      String? requested;
      harness.fixture.respond = (request) async {
        if (request.url.path.endsWith('/playback-leases')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          requested = body['requestId']! as String;
          return harness.fixture.json(
            _lease(
              scenario == 0 ? 'f' * 32 : requested!,
              harness.fixture.now.add(const Duration(minutes: 2)),
              revision: scenario == 0 ? 1 : 2,
            ),
          );
        }
        if (request.url.path.endsWith('/retire')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          retired.add((
            id: request.url.pathSegments[request.url.pathSegments.length - 2],
            revision: body['expectedRevision']! as int,
          ));
          return harness.fixture.json({});
        }
        return harness.fixture.defaultResponse(request);
      };

      expect(
        await source.open(
          _binding(),
          mode: CoreCatalogPlayerSourceMode.coreLease,
          authorization: authorization,
          current: () => true,
        ),
        isNull,
      );
      expect(retired.last, (id: requested, revision: 1));
      expect(retired.last.id, isNot('f' * 32));
    }
  });

  test(
    'account token rotation invalidates instead of adopting the new bearer',
    () async {
      final harness = await _authorizedFixture();
      addTearDown(harness.fixture.account.dispose);
      final source = CoreLeaseCatalogPlayerSource(
        harness.fixture.account,
        capability: harness.adapter,
        clock: () => harness.fixture.now,
      );
      addTearDown(source.dispose);
      final authorization = await harness.authorize('4' * 32);
      var renews = 0;
      harness.fixture.respond = (request) async {
        if (request.url.path.endsWith('/playback-leases')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return harness.fixture.json(
            _lease(
              body['requestId']! as String,
              harness.fixture.now.add(const Duration(minutes: 2)),
            ),
          );
        }
        if (request.url.path.endsWith('/renew')) renews++;
        return harness.fixture.defaultResponse(request);
      };
      final lease = await source.open(
        _binding(),
        mode: CoreCatalogPlayerSourceMode.coreLease,
        authorization: authorization,
        current: () => true,
      );
      expect(lease, isNotNull);

      harness.fixture.now = harness.fixture.now.add(
        const Duration(minutes: 59, seconds: 31),
      );
      await harness.fixture.account.ensureSession();

      expect(
        await lease!.invalidated.timeout(const Duration(seconds: 1)),
        'lease_unavailable',
      );
      expect(renews, 0);
    },
  );

  testWidgets('native profile drift invalidates before renew HTTP', (
    tester,
  ) async {
    final harness = await _authorizedFixture();
    addTearDown(harness.fixture.account.dispose);
    final source = CoreLeaseCatalogPlayerSource(
      harness.fixture.account,
      capability: harness.adapter,
      clock: () => harness.fixture.now,
    );
    addTearDown(source.dispose);
    final authorization = await harness.authorize('4' * 32);
    var renews = 0;
    harness.fixture.respond = (request) async {
      if (request.url.path.endsWith('/playback-leases')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return harness.fixture.json(
          _lease(
            body['requestId']! as String,
            harness.fixture.now.add(const Duration(seconds: 4)),
          ),
        );
      }
      if (request.url.path.endsWith('/renew')) renews++;
      return harness.fixture.defaultResponse(request);
    };
    final lease = await source.open(
      _binding(),
      mode: CoreCatalogPlayerSourceMode.coreLease,
      authorization: authorization,
      current: () => true,
    );
    expect(lease, isNotNull);
    harness.port.value = _native(networkRevision: 14);
    harness.fixture.now = harness.fixture.now.add(const Duration(seconds: 2));

    await tester.pump(const Duration(seconds: 2));
    expect(await lease!.invalidated, 'lease_unavailable');
    expect(renews, 0);
  });

  testWidgets(
    'renew rejects different id/revision and retires exact owned id',
    (tester) async {
      final harness = await _authorizedFixture();
      addTearDown(harness.fixture.account.dispose);
      final source = CoreLeaseCatalogPlayerSource(
        harness.fixture.account,
        capability: harness.adapter,
        random: Random(11),
        clock: () => harness.fixture.now,
      );
      addTearDown(source.dispose);
      final authorization = await harness.authorize('4' * 32);
      String? owned;
      final retired = <({String id, int revision})>[];
      harness.fixture.respond = (request) async {
        if (request.url.path.endsWith('/playback-leases')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          owned = body['requestId']! as String;
          return harness.fixture.json(
            _lease(owned!, harness.fixture.now.add(const Duration(seconds: 4))),
          );
        }
        if (request.url.path.endsWith('/renew')) {
          return harness.fixture.json(
            _lease(
              'e' * 32,
              harness.fixture.now.add(const Duration(minutes: 2)),
              revision: 3,
            ),
          );
        }
        if (request.url.path.endsWith('/retire')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          retired.add((
            id: request.url.pathSegments[request.url.pathSegments.length - 2],
            revision: body['expectedRevision']! as int,
          ));
          return harness.fixture.json({});
        }
        return harness.fixture.defaultResponse(request);
      };
      final lease = await source.open(
        _binding(),
        mode: CoreCatalogPlayerSourceMode.coreLease,
        authorization: authorization,
        current: () => true,
      );
      harness.fixture.now = harness.fixture.now.add(const Duration(seconds: 2));

      await tester.pump(const Duration(seconds: 2));

      expect(await lease!.invalidated, 'lease_unavailable');
      expect(retired, isNotEmpty);
      expect(retired.every((value) => value.id == owned), isTrue);
      expect(retired.first.revision, 2);
      expect(retired.any((value) => value.id == 'e' * 32), isFalse);
    },
  );

  testWidgets('renew authority mismatch retires exact next owned revision', (
    tester,
  ) async {
    final harness = await _authorizedFixture();
    addTearDown(harness.fixture.account.dispose);
    final source = CoreLeaseCatalogPlayerSource(
      harness.fixture.account,
      capability: harness.adapter,
      random: Random(13),
      clock: () => harness.fixture.now,
    );
    addTearDown(source.dispose);
    final authorization = await harness.authorize('4' * 32);
    String? owned;
    final retired = <({String id, int revision})>[];
    harness.fixture.respond = (request) async {
      if (request.url.path.endsWith('/playback-leases')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        owned = body['requestId']! as String;
        return harness.fixture.json(
          _lease(owned!, harness.fixture.now.add(const Duration(seconds: 4))),
        );
      }
      if (request.url.path.endsWith('/renew')) {
        final malformed = _lease(
          owned!,
          harness.fixture.now.add(const Duration(minutes: 2)),
          revision: 2,
        );
        final lease = malformed['lease']! as Map<String, Object?>;
        final authority = lease['authority']! as Map<String, Object?>;
        authority['homeId'] = 'c' * 32;
        return harness.fixture.json(malformed);
      }
      if (request.url.path.endsWith('/retire')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        retired.add((
          id: request.url.pathSegments[request.url.pathSegments.length - 2],
          revision: body['expectedRevision']! as int,
        ));
        return harness.fixture.json({});
      }
      return harness.fixture.defaultResponse(request);
    };
    final lease = await source.open(
      _binding(),
      mode: CoreCatalogPlayerSourceMode.coreLease,
      authorization: authorization,
      current: () => true,
    );
    harness.fixture.now = harness.fixture.now.add(const Duration(seconds: 2));

    await tester.pump(const Duration(seconds: 2));

    expect(await lease!.invalidated, 'lease_unavailable');
    expect(retired, isNotEmpty);
    expect(retired.every((value) => value.id == owned), isTrue);
    expect(retired.first.revision, 2);
  });

  test(
    'offline source restores verified vault and never overwrites corruption',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final root = await Directory.systemTemp.createTemp(
        'larenor-source-offline-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final vault = ServerOfflineMediaVault(root: () async => root);
      final manifest = _offlineManifest(fixture, '8' * 32, bytes);
      await vault.writeChunk(manifest.grantId, 0, bytes);
      await vault.storeCompletedManifest(manifest);
      final controller = ServerOfflineMediaController(
        fixture.account,
        vault: vault,
      );
      final source = OfflineVaultCoreCatalogPlayerSource(
        fixture.account,
        offline: controller,
      );
      addTearDown(source.dispose);
      final callsBefore = fixture.calls.length;

      final restored = await source.open(
        _binding(),
        mode: CoreCatalogPlayerSourceMode.offlineVault,
        authorization: null,
        current: () => true,
      );

      expect(restored, isNotNull);
      expect(fixture.calls, hasLength(callsBefore));
      await restored!.close();
      source.retire();

      final chunk = File(
        '${root.path}/${manifest.grantId}/0000000000000000.chunk',
      );
      await chunk.writeAsBytes([1, 2, 3], flush: true);
      final corruptController = ServerOfflineMediaController(
        fixture.account,
        vault: ServerOfflineMediaVault(root: () async => root),
      );
      final corruptSource = OfflineVaultCoreCatalogPlayerSource(
        fixture.account,
        offline: corruptController,
      );
      addTearDown(corruptSource.dispose);
      final callsBeforeCorrupt = fixture.calls.length;

      expect(
        await corruptSource.open(
          _binding(),
          mode: CoreCatalogPlayerSourceMode.offlineVault,
          authorization: null,
          current: () => true,
        ),
        isNull,
      );
      expect(corruptController.failure, 'offline_media_integrity_failed');
      expect(fixture.calls, hasLength(callsBeforeCorrupt));
    },
  );
}
