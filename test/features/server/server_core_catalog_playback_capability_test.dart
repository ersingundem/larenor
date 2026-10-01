import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/local_media_player/data/core_catalog_playback_capability_adapter.dart';
import 'package:larenor/features/server/local_media_player/domain/core_catalog_player_binding.dart';
import 'package:larenor/features/server/local_media_player/presentation/core_catalog_playback_quality_panel.dart';
import 'package:larenor/features/server/media_catalog/domain/server_media_catalog_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'server_admin_test_support.dart';

const _installation = '11111111111111111111111111111111';
const _item = '22222222222222222222222222222222';
const _sourceObservation = <String, Object?>{
  'container': 'mp4',
  'bitrateBps': 12000000,
  'videoCodecs': ['h264'],
  'audioCodecs': ['aac'],
  'videoRanges': ['SDR'],
};

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

final class _SequencedPort implements CoreCatalogPlaybackCapabilityPort {
  _SequencedPort(this.values);
  final List<Future<Object?>> values;
  var reads = 0;

  @override
  Future<Object?> snapshot() {
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
  bool recorded = false,
  String outcome = 'direct_play_supported',
  String method = 'direct_play',
  String reason = 'available',
  int lifetimeSeconds = 30,
  Object? source = _sourceObservation,
  Object? transcoding,
}) => {
  'schemaVersion': 1,
  'requestId': '3' * 32,
  if (recorded) 'observationId': '4' * 32,
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
    'source': source,
    'transcoding': transcoding,
    'reason': reason,
    'advisoryOnly': true,
    'physicalAcceptance': 'manual',
    'observedAt': observedAt,
    'expiresAt': observedAt + lifetimeSeconds,
  },
};

Future<CoreCatalogLocalPlaybackProfile> _profile(AdminFixture fixture) async {
  return (await CoreCatalogPlaybackCapabilityAdapter(
    fixture.account,
    port: _Port([_native()]),
  ).capture())!;
}

Future<void> _mountPanel(
  WidgetTester tester, {
  required AdminFixture fixture,
  required CoreCatalogPlaybackCapabilityAdapter adapter,
  required bool Function() current,
  String locale = 'en',
}) async {
  await tester.pumpWidget(
    CupertinoApp(
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: const [Locale('en'), Locale('tr')],
      home: CupertinoPageScaffold(
        child: CoreCatalogPlaybackQualityPanel(
          adapter: adapter,
          binding: _binding(),
          current: current,
        ),
      ),
    ),
  );
}

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
            recorded: true,
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
          recorded: true,
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
          recorded: true,
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

  test('advice uses a non-recording request and explicit play obtains its own observation', () async {
    final fixture = AdminFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final profile = await _profile(fixture);
    fixture.respond = (request) async => fixture.json(
      _response(
        profile: profile,
        observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
        recorded: request.url.path.endsWith('/observe-item'),
      ),
    );
    final adapter = CoreCatalogPlaybackCapabilityAdapter(
      fixture.account,
      port: _Port(List.filled(4, _native())),
      requestId: () => '3' * 32,
      clock: () => fixture.now,
    );

    expect(
      (await adapter.assess(_binding(), current: () => true))?.outcome,
      CoreCatalogPlaybackOutcome.directPlaySupported,
    );
    expect(
      fixture.calls.where((call) => call.url.path.endsWith('/assess-item')),
      hasLength(1),
    );
    expect(
      fixture.calls.where((call) => call.url.path.endsWith('/observe-item')),
      isEmpty,
    );
    expect(
      (await adapter.observe(_binding(), current: () => true))?.observationId,
      '4' * 32,
    );
    expect(
      fixture.calls.where((call) => call.url.path.endsWith('/observe-item')),
      hasLength(1),
    );
  });

  test('advice cannot carry an observation ID and playback cannot use an ID-free response', () async {
    final fixture = AdminFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final profile = await _profile(fixture);
    final adapter = CoreCatalogPlaybackCapabilityAdapter(
      fixture.account,
      port: _Port(List.filled(4, _native())),
      requestId: () => '3' * 32,
      clock: () => fixture.now,
    );
    fixture.respond = (request) async => fixture.json(
      _response(
        profile: profile,
        observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
        recorded: request.url.path.endsWith('/assess-item'),
      ),
    );

    expect(await adapter.assess(_binding(), current: () => true), isNull);
    expect(await adapter.observe(_binding(), current: () => true), isNull);
  });

  test(
    'assessment accepts every coherent provider outcome without authorizing',
    () async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final profile = await _profile(fixture);
      final responses = <Map<String, Object?>>[
        _response(profile: profile, observedAt: 1),
        _response(
          profile: profile,
          observedAt: 1,
          outcome: 'requires_remux',
          method: 'direct_stream',
        ),
        _response(
          profile: profile,
          observedAt: 1,
          outcome: 'requires_transcode',
          method: 'transcode',
          transcoding: const {
            'container': 'ts',
            'videoCodec': 'h264',
            'audioCodec': 'aac',
            'bitrateBps': 9000000,
            'reasons': ['ContainerNotSupported'],
          },
        ),
        _response(
          profile: profile,
          observedAt: 1,
          outcome: 'unavailable',
          method: 'unknown',
          reason: 'no_supported_method',
          source: null,
        ),
        _response(
          profile: profile,
          observedAt: 1,
          outcome: 'contract_unknown',
          method: 'unknown',
          reason: 'multiple_sources',
          source: null,
        ),
      ];
      var index = 0;
      fixture.respond = (_) async => fixture.json(responses[index++]);
      final adapter = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: _Port(List.filled(10, _native())),
        requestId: () => '3' * 32,
        clock: () => DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
      );

      final assessments = <CoreCatalogPlaybackAssessment?>[];
      for (var count = 0; count < responses.length; count++) {
        assessments.add(await adapter.assess(_binding(), current: () => true));
      }

      expect(
        assessments.map((value) => value?.outcome),
        CoreCatalogPlaybackOutcome.values,
      );
      expect(assessments[0]?.allowsOriginalBytes, isTrue);
      expect(assessments[1]?.source?.container, 'mp4');
      expect(assessments[2]?.transcoding?.reasons, ['ContainerNotSupported']);
      expect(assessments[3]?.source, isNull);
      expect(assessments[4]?.reason, CoreCatalogPlaybackReason.multipleSources);
      expect(
        await adapter.observe(_binding(), current: () => true),
        isNull,
        reason:
            'an exhausted fixture cannot fabricate Direct Play authorization',
      );
    },
  );

  test(
    'assessment rejects forged schema, incoherent evidence, expiry and drift',
    () async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final profile = await _profile(fixture);
      final now = fixture.now.millisecondsSinceEpoch ~/ 1000;
      final cases = <Map<String, Object?>>[
        {
          ..._response(profile: profile, observedAt: now),
          'providerUrl': 'https://private.invalid',
        },
        _response(
          profile: profile,
          observedAt: now,
          outcome: 'requires_remux',
          method: 'direct_stream',
          transcoding: const {
            'container': 'ts',
            'videoCodec': 'h264',
            'audioCodec': 'aac',
            'bitrateBps': 1,
            'reasons': <String>[],
          },
        ),
        _response(
          profile: profile,
          observedAt: now,
          source: {..._sourceObservation, 'providerId': 'private-source'},
        ),
        _response(profile: profile, observedAt: now - 31, lifetimeSeconds: 30),
        _response(profile: profile, observedAt: now + 1),
      ];
      var index = 0;
      fixture.respond = (_) async => fixture.json(cases[index++]);
      final adapter = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: _Port([
          _native(),
          _native(),
          _native(),
          _native(),
          _native(),
          _native(networkRevision: 99),
        ]),
        requestId: () => '3' * 32,
        clock: () => fixture.now,
      );

      for (var count = 0; count < cases.length; count++) {
        expect(await adapter.assess(_binding(), current: () => true), isNull);
      }

      fixture.respond = (_) async =>
          fixture.json(_response(profile: profile, observedAt: now));
      expect(await adapter.assess(_binding(), current: () => false), isNull);

      final nativeDrift = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: _Port([_native(), _native(networkRevision: 99)]),
        requestId: () => '3' * 32,
        clock: () => fixture.now,
      );
      expect(await nativeDrift.assess(_binding(), current: () => true), isNull);
    },
  );

  test('scope retirement discards an in-flight assessment result', () async {
    final fixture = AdminFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final profile = await _profile(fixture);
    final delayed = Completer<http.Response>();
    fixture.respond = (request) {
      if (request.url.path.endsWith('/assess-item')) return delayed.future;
      return Future.value(fixture.defaultResponse(request));
    };
    final adapter = CoreCatalogPlaybackCapabilityAdapter(
      fixture.account,
      port: _Port(List.filled(4, _native())),
      requestId: () => '3' * 32,
      clock: () => fixture.now,
    );
    final pending = adapter.assess(_binding(), current: () => true);
    while (!fixture.calls.any(
      (call) => call.url.path.endsWith('/assess-item'),
    )) {
      await Future<void>.delayed(Duration.zero);
    }
    await fixture.account.signOut();
    delayed.complete(
      fixture.json(
        _response(
          profile: profile,
          observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
        ),
      ),
    );

    expect(await pending, isNull);
  });

  testWidgets('panel shows bounded loading, advice and actual observed facts', (
    tester,
  ) async {
    final fixture = AdminFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final profile = await _profile(fixture);
    final response = Completer<http.Response>();
    fixture.respond = (_) => response.future;
    final adapter = CoreCatalogPlaybackCapabilityAdapter(
      fixture.account,
      port: _Port(List.filled(4, _native())),
      requestId: () => '3' * 32,
      clock: () => fixture.now,
    );

    await _mountPanel(
      tester,
      fixture: fixture,
      adapter: adapter,
      current: () => true,
    );
    expect(find.byKey(const ValueKey('quality-loading')), findsOneWidget);

    response.complete(
      fixture.json(
        _response(
          profile: profile,
          observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
          outcome: 'requires_transcode',
          method: 'transcode',
          transcoding: const {
            'container': 'ts',
            'videoCodec': 'h264',
            'audioCodec': 'aac',
            'bitrateBps': 9000000,
            'reasons': ['ContainerNotSupported'],
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Transcoding advised'), findsOneWidget);
    expect(find.textContaining('12.0 Mbps'), findsOneWidget);
    expect(find.textContaining('H.264'), findsWidgets);
    expect(find.textContaining('2560 × 1440'), findsOneWidget);
    expect(find.textContaining('20.0 Mbps'), findsOneWidget);
    expect(find.textContaining('not measured'), findsOneWidget);
    expect(find.textContaining('manual'), findsOneWidget);
    expect(find.textContaining('private.invalid'), findsNothing);
  });

  testWidgets('panel failure retries accessibly and Turkish copy is explicit', (
    tester,
  ) async {
    final fixture = AdminFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final profile = await _profile(fixture);
    var fail = true;
    fixture.respond = (_) async => fail
        ? fixture.json({
            'error': {'code': 'server_unavailable'},
          }, 503)
        : fixture.json(
            _response(
              profile: profile,
              observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
            ),
          );
    final adapter = CoreCatalogPlaybackCapabilityAdapter(
      fixture.account,
      port: _Port(List.filled(5, _native())),
      requestId: () => '3' * 32,
      clock: () => fixture.now,
    );

    await _mountPanel(
      tester,
      fixture: fixture,
      adapter: adapter,
      current: () => true,
      locale: 'tr',
    );
    await tester.pumpAndSettle();
    expect(find.text('Kalite bilgisi alınamadı'), findsOneWidget);
    final retry = find.byKey(const ValueKey('quality-retry'));
    expect(tester.getSemantics(retry).flagsCollection.isButton, isTrue);
    fail = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(find.text('Doğrudan Oynatma uygun'), findsOneWidget);
    expect(find.textContaining('ölçülmedi'), findsOneWidget);
  });

  testWidgets(
    'parent retirement clears advice and disables retry immediately',
    (tester) async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final profile = await _profile(fixture);
      fixture.respond = (_) async => fixture.json(
        _response(
          profile: profile,
          observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
        ),
      );
      final adapter = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: _Port(List.filled(4, _native())),
        requestId: () => '3' * 32,
        clock: () => fixture.now,
      );
      var current = true;
      bool isCurrent() => current;
      await _mountPanel(
        tester,
        fixture: fixture,
        adapter: adapter,
        current: isCurrent,
      );
      await tester.pumpAndSettle();
      expect(find.text('Direct Play is suitable'), findsOneWidget);

      current = false;
      await _mountPanel(
        tester,
        fixture: fixture,
        adapter: adapter,
        current: isCurrent,
      );
      await tester.pump();

      expect(find.text('Direct Play is suitable'), findsNothing);
      final retry = tester.widget<CupertinoButton>(
        find.byKey(const ValueKey('quality-retry')),
      );
      expect(retry.onPressed, isNull);
    },
  );

  for (final value
      in <
        ({
          String outcome,
          String method,
          String reason,
          Object? source,
          String title,
          String recommendation,
        })
      >[
        (
          outcome: 'requires_remux',
          method: 'direct_stream',
          reason: 'available',
          source: const {
            'container': 'mp4',
            'bitrateBps': 12000000,
            'videoCodecs': ['h264'],
            'audioCodecs': ['aac'],
            'videoRanges': ['SDR'],
          },
          title: 'Remux is advised',
          recommendation: 'repackage the stream',
        ),
        (
          outcome: 'unavailable',
          method: 'unknown',
          reason: 'no_supported_method',
          source: null,
          title: 'No compatible method',
          recommendation: 'No supported playback method',
        ),
        (
          outcome: 'contract_unknown',
          method: 'unknown',
          reason: 'contract_unsupported',
          source: null,
          title: 'Compatibility is unknown',
          recommendation: 'did not yield a definite recommendation',
        ),
      ]) {
    testWidgets('panel explains ${value.outcome} without claiming playback', (
      tester,
    ) async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final profile = await _profile(fixture);
      fixture.respond = (_) async => fixture.json(
        _response(
          profile: profile,
          observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
          outcome: value.outcome,
          method: value.method,
          reason: value.reason,
          source: value.source,
        ),
      );
      final adapter = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: _Port(List.filled(4, _native())),
        requestId: () => '3' * 32,
        clock: () => fixture.now,
      );

      await _mountPanel(
        tester,
        fixture: fixture,
        adapter: adapter,
        current: () => true,
      );
      await tester.pumpAndSettle();

      expect(find.text(value.title), findsOneWidget);
      expect(find.textContaining(value.recommendation), findsOneWidget);
      expect(find.textContaining('guaranteed'), findsNothing);
      expect(
        fixture.calls.where(
          (call) => call.url.path.contains('/playback-leases'),
        ),
        isEmpty,
      );
    });
  }

  testWidgets('panel loading deadline becomes a bounded retry state', (
    tester,
  ) async {
    final fixture = AdminFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final delayed = Completer<http.Response>();
    fixture.respond = (_) => delayed.future;
    final adapter = CoreCatalogPlaybackCapabilityAdapter(
      fixture.account,
      port: _Port(List.filled(2, _native())),
      requestId: () => '3' * 32,
      clock: () => fixture.now,
    );
    await _mountPanel(
      tester,
      fixture: fixture,
      adapter: adapter,
      current: () => true,
    );
    expect(find.byKey(const ValueKey('quality-loading')), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(find.text('Quality advice is unavailable'), findsOneWidget);
    expect(find.byKey(const ValueKey('quality-retry')), findsOneWidget);
    delayed.complete(
      fixture.json({
        'error': {'code': 'server_unavailable'},
      }, 503),
    );
    await tester.pump();
  });

  testWidgets(
    'disposing a pending default-deadline assessment cancels its timer and rejects its late result',
    (tester) async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final profile = await _profile(fixture);
      final delayed = Completer<http.Response>();
      addTearDown(() {
        if (!delayed.isCompleted) {
          delayed.complete(
            fixture.json({
              'error': {'code': 'server_unavailable'},
            }, 503),
          );
        }
      });
      fixture.respond = (_) => delayed.future;
      final adapter = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: _Port(List.filled(4, _native())),
        requestId: () => '3' * 32,
        clock: () => fixture.now,
      );
      await _mountPanel(
        tester,
        fixture: fixture,
        adapter: adapter,
        current: () => true,
      );
      expect(find.byKey(const ValueKey('quality-loading')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      delayed.complete(
        fixture.json(
          _response(
            profile: profile,
            observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('quality-assessment')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'background retirement cancels pending load and rejects its late assessment',
    (tester) async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final profile = await _profile(fixture);
      final delayed = Completer<http.Response>();
      addTearDown(() {
        if (!delayed.isCompleted) {
          delayed.complete(
            fixture.json({
              'error': {'code': 'server_unavailable'},
            }, 503),
          );
        }
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
      fixture.respond = (_) => delayed.future;
      final adapter = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: _Port(List.filled(4, _native())),
        requestId: () => '3' * 32,
        clock: () => fixture.now,
      );
      await _mountPanel(
        tester,
        fixture: fixture,
        adapter: adapter,
        current: () => true,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();

      delayed.complete(
        fixture.json(
          _response(
            profile: profile,
            observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('quality-assessment')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'adapter replacement cancels old load and only successor advice can bind',
    (tester) async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final profile = await _profile(fixture);
      final delayed = Completer<http.Response>();
      addTearDown(() {
        if (!delayed.isCompleted) {
          delayed.complete(
            fixture.json({
              'error': {'code': 'server_unavailable'},
            }, 503),
          );
        }
      });
      var requests = 0;
      fixture.respond = (_) {
        requests++;
        if (requests == 1) return delayed.future;
        return Future.value(
          fixture.json(
            _response(
              profile: profile,
              observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
            ),
          ),
        );
      };
      final first = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: _Port(List.filled(4, _native())),
        requestId: () => '3' * 32,
        clock: () => fixture.now,
      );
      final successor = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: _Port(List.filled(4, _native())),
        requestId: () => '3' * 32,
        clock: () => fixture.now,
      );
      await _mountPanel(
        tester,
        fixture: fixture,
        adapter: first,
        current: () => true,
      );
      await _mountPanel(
        tester,
        fixture: fixture,
        adapter: successor,
        current: () => true,
      );
      await tester.pumpAndSettle();
      expect(find.text('Direct Play is suitable'), findsOneWidget);

      delayed.complete(
        fixture.json(
          _response(
            profile: profile,
            observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
            outcome: 'requires_transcode',
            method: 'transcode',
            transcoding: const {
              'container': 'ts',
              'videoCodec': 'h264',
              'audioCodec': 'aac',
              'bitrateBps': 9000000,
              'reasons': ['ContainerNotSupported'],
            },
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Direct Play is suitable'), findsOneWidget);
      expect(find.text('Transcoding advised'), findsNothing);
    },
  );

  testWidgets(
    'disposing during native authority revalidation cancels its owned deadline',
    (tester) async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final profile = await _profile(fixture);
      final passwordResponse = Completer<http.Response>();
      addTearDown(() {
        if (!passwordResponse.isCompleted) {
          passwordResponse.complete(
            fixture.json({
              'error': {'code': 'rate_limited'},
            }, 429),
          );
        }
      });
      fixture.respond = (request) {
        if (request.url.path.endsWith('/auth/password')) {
          return passwordResponse.future;
        }
        return Future.value(
          fixture.json(
            _response(
              profile: profile,
              observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
            ),
          ),
        );
      };
      final pendingNative = Completer<Object?>();
      addTearDown(() {
        if (!pendingNative.isCompleted) pendingNative.complete(_native());
      });
      final port = _SequencedPort([
        Future.value(_native()),
        Future.value(_native()),
        pendingNative.future,
      ]);
      final adapter = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: port,
        requestId: () => '3' * 32,
        clock: () => fixture.now,
      );
      await _mountPanel(
        tester,
        fixture: fixture,
        adapter: adapter,
        current: () => true,
      );
      await tester.pumpAndSettle();
      expect(find.text('Direct Play is suitable'), findsOneWidget);

      final passwordChange = fixture.account.changePassword(
        currentPassword: 'synthetic current password',
        newPassword: 'synthetic replacement password',
      );
      await tester.pump();
      expect(port.reads, greaterThanOrEqualTo(3));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      pendingNative.complete(_native());
      passwordResponse.complete(
        fixture.json({
          'error': {'code': 'rate_limited'},
        }, 429),
      );
      await passwordChange;
      await tester.pump();

      expect(find.byKey(const ValueKey('quality-assessment')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late result, lifecycle loss and expiry clear stale advice', (
    tester,
  ) async {
    final fixture = AdminFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final profile = await _profile(fixture);
    var current = true;
    final delayed = Completer<http.Response>();
    fixture.respond = (_) => delayed.future;
    final adapter = CoreCatalogPlaybackCapabilityAdapter(
      fixture.account,
      port: _Port(List.filled(8, _native())),
      requestId: () => '3' * 32,
      clock: () => fixture.now,
    );
    await _mountPanel(
      tester,
      fixture: fixture,
      adapter: adapter,
      current: () => current,
    );
    current = false;
    delayed.complete(
      fixture.json(
        _response(
          profile: profile,
          observedAt: fixture.now.millisecondsSinceEpoch ~/ 1000,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Direct Play is suitable'), findsNothing);

    current = true;
    await tester.tap(find.byKey(const ValueKey('quality-retry')));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(find.text('Direct Play is suitable'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Direct Play is suitable'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Direct Play is suitable'), findsNothing);
  });
}
