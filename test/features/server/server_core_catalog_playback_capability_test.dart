import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/local_media_player/data/core_catalog_playback_capability_adapter.dart';
import 'package:larenor/features/server/local_media_player/domain/core_catalog_player_binding.dart';
import 'package:larenor/features/server/media_catalog/domain/server_media_catalog_models.dart';

import 'server_admin_test_support.dart';

const _installation = '11111111111111111111111111111111';
const _item = '22222222222222222222222222222222';

final class _Port implements CoreCatalogPlaybackCapabilityPort {
  _Port(this.values);
  final List<Object?> values;
  var reads = 0;

  @override
  Future<Object?> snapshot() async {
    final index = reads < values.length ? reads : values.length - 1;
    reads++;
    return values[index];
  }
}

Map<String, Object?> _native({
  int displayRevision = 11,
  int decoderRevision = 12,
  int networkRevision = 13,
  bool truncated = false,
}) => {
  'schemaVersion': 1,
  'displayWidthPixels': 2560,
  'displayHeightPixels': 1440,
  'displayRevision': displayRevision,
  'decoderMimeTypes': [
    'audio/eac3',
    'audio/mp4a-latm',
    'video/avc',
    'video/hevc',
  ],
  'decoderMimeTypesTruncated': truncated,
  'decoderRevision': decoderRevision,
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

Map<String, Object?> _response({
  required CoreCatalogLocalPlaybackProfile profile,
  required int observedAt,
  String outcome = 'direct_play_supported',
  String method = 'direct_play',
}) => {
  'schemaVersion': 1,
  'requestId': '3' * 32,
  'observationId': '4' * 32,
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
    'originalByteOutcome': outcome,
    'playMethod': method,
    'source': {
      'container': 'mp4',
      'bitrateBps': 12000000,
      'videoCodecs': ['h264'],
      'audioCodecs': ['aac'],
      'videoRanges': ['SDR'],
    },
    'transcoding': null,
    'reason': outcome == 'direct_play_supported'
        ? 'available'
        : 'original_byte_mismatch',
    'advisoryOnly': true,
    'physicalAcceptance': 'manual',
    'observedAt': observedAt,
    'expiresAt': observedAt + 30,
  },
};

void main() {
  test(
    'actual native facts build one conservative client-reported profile',
    () async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final adapter = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: _Port([_native()]),
      );

      final profile = await adapter.capture();

      expect(profile, isNotNull);
      expect(profile!.profileId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(profile.profileRevision, inInclusiveRange(1, 9007199254740991));
      expect(profile.displayRevision, 11);
      expect(profile.decoderRevision, 12);
      expect(profile.networkRevision, 13);
      expect(profile.containers, ['mp4']);
      expect(profile.videoCodecs, ['h264', 'hevc']);
      expect(profile.audioCodecs, ['aac', 'eac3']);
      expect(profile.subtitleFormats, isEmpty);
      expect(profile.maxWidth, 2560);
      expect(profile.maxHeight, 1440);
      expect(profile.maxStreamingBitrateBps, 20000000);
      expect(profile.toJson()['evidence'], 'client_reported');
      expect(profile.toJson(), isNot(contains('hdrPlaybackVerified')));
      expect(profile.toJson(), isNot(contains('hardwareAccelerated')));
    },
  );

  test(
    'direct-play observation is exact and current native facts are reread',
    () async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final port = _Port([_native(), _native(), _native()]);
      final adapter = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: port,
        requestId: () => '3' * 32,
        clock: () => fixture.now,
      );
      final profile = (await adapter.capture())!;
      fixture.respond = (request) async {
        expect(
          request.url.path,
          endsWith(
            '/media/playback-quality/${'a' * 32}/${'b' * 32}/observe-item',
          ),
        );
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body.keys.toSet(), {
          'schemaVersion',
          'requestId',
          'installationId',
          'expectedInstallationRevision',
          'expectedSnapshotRevision',
          'expectedJellyfinServiceRevision',
          'itemId',
          'mediaKey',
          'localProfile',
        });
        expect(body['localProfile'], profile.toJson());
        return fixture.json(
          _response(
            profile: profile,
            observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
          ),
        );
      };

      final authorization = await adapter.observe(
        _binding(),
        current: () => true,
      );

      expect(authorization?.observationId, '4' * 32);
      expect(authorization?.profile.digest, profile.digest);
      expect(port.reads, 3);
      expect(
        await adapter.revalidate(authorization!, current: () => true),
        isTrue,
      );
      await fixture.account.signOut();
      expect(
        await adapter.revalidate(authorization, current: () => true),
        isFalse,
      );
    },
  );

  test(
    'native drift or non-direct provider outcome never authorizes a lease',
    () async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final port = _Port([_native(), _native(networkRevision: 14)]);
      final adapter = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: port,
        requestId: () => '3' * 32,
        clock: () => fixture.now,
      );
      final stable = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: _Port([_native()]),
      );
      final profile = (await stable.capture())!;
      fixture.respond = (request) async => fixture.json(
        _response(
          profile: profile,
          observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
        ),
      );
      expect(await adapter.observe(_binding(), current: () => true), isNull);

      final remux = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: _Port([_native(), _native()]),
        requestId: () => '3' * 32,
        clock: () => fixture.now,
      );
      fixture.respond = (request) async => fixture.json(
        _response(
          profile: profile,
          observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
          outcome: 'requires_remux',
          method: 'direct_stream',
        ),
      );
      expect(await remux.observe(_binding(), current: () => true), isNull);
    },
  );

  test(
    'truncated or malformed native evidence fails closed before HTTP',
    () async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final truncated = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: _Port([_native(truncated: true)]),
      );
      final malformed = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: _Port([
          {..._native(), 'networkRevision': 0},
        ]),
      );

      expect(await truncated.capture(), isNull);
      expect(await malformed.capture(), isNull);
      expect(fixture.calls.where((value) => value.method == 'POST'), isEmpty);
    },
  );
}
