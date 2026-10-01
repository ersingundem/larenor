import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/presentation/player/jellyfin_player_screen.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_track_preferences_store.dart';
import 'package:larenor/features/media/jellyfin/domain/jellyfin_track_preferences.dart';
import 'package:larenor/features/media/local_audio/data/local_audio_bridge.dart';
import 'package:larenor/features/media/local_audio/providers/local_audio_providers.dart';
import 'package:larenor/features/server/local_media_player/data/core_catalog_playback_capability_adapter.dart';
import 'package:larenor/features/server/local_media_player/data/core_catalog_player_source.dart';
import 'package:larenor/features/server/local_media_player/domain/core_catalog_player_binding.dart';
import 'package:larenor/features/server/local_media_player/presentation/core_catalog_player_screen.dart';
import 'package:larenor/features/server/media_catalog/domain/server_media_catalog_models.dart';
import 'package:larenor/features/server/offline_media/domain/server_offline_media_models.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:media_kit/media_kit.dart';

import 'server_admin_test_support.dart';

const _installation = '11111111111111111111111111111111';
const _itemId = '22222222222222222222222222222222';

final class _CapabilityPort implements CoreCatalogPlaybackCapabilityPort {
  @override
  Future<Object?> snapshot() async => {
    'schemaVersion': 1,
    'displayWidthPixels': 1920,
    'displayHeightPixels': 1080,
    'displayRevision': 11,
    'decoderMimeTypes': ['audio/mp4a-latm', 'video/avc'],
    'decoderMimeTypesTruncated': false,
    'decoderRevision': 12,
    'networkTransports': ['wifi'],
    'networkValidated': true,
    'networkMetered': false,
    'networkDownstreamKbps': 50000,
    'networkRevision': 13,
  };
}

Map<String, Object?> _qualityResponse(
  CoreCatalogLocalPlaybackProfile profile,
  int now,
) => {
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
    'itemId': _itemId,
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
      'bitrateBps': 8000000,
      'videoCodecs': ['h264'],
      'audioCodecs': ['aac'],
      'videoRanges': <String>[],
    },
    'transcoding': null,
    'reason': 'available',
    'advisoryOnly': true,
    'physicalAcceptance': 'manual',
    'observedAt': now,
    'expiresAt': now + 30,
  },
};

Future<void> _scrollUntilBuilt(WidgetTester tester, Finder finder) async {
  for (var index = 0; index < 60 && finder.evaluate().isEmpty; index++) {
    await tester.drag(find.byType(ListView), const Offset(0, -40));
    await tester.pump();
  }
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pump();
  final rect = tester.getRect(finder);
  final logicalHeight =
      tester.view.physicalSize.height / tester.view.devicePixelRatio;
  if (rect.bottom > logicalHeight - 20) {
    await tester.drag(
      find.byType(ListView),
      Offset(0, -(rect.bottom - logicalHeight + 40)),
    );
    await tester.pump();
  } else if (rect.top < 20) {
    await tester.drag(find.byType(ListView), Offset(0, 40 - rect.top));
    await tester.pump();
  }
  expect(finder.hitTestable(), findsOneWidget);
}

void _useTallViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1400);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

ServerMediaCatalogPage _page({int snapshotRevision = 7}) =>
    ServerMediaCatalogPage.fromJson(
      {
        'schemaVersion': 1,
        'installationId': _installation,
        'installationRevision': 5,
        'snapshotRevision': snapshotRevision,
        'jellyfinServiceRevision': 9,
        'offset': 0,
        'nextOffset': null,
        'total': 1,
        'items': [
          {
            'itemId': _itemId,
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

ServerOfflineMediaManifest _manifest(
  AdminFixture fixture, {
  int snapshotRevision = 7,
}) => ServerOfflineMediaManifest.fromJson({
  'schemaVersion': 1,
  'grantId': '33333333333333333333333333333333',
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
    'snapshotRevision': snapshotRevision,
    'jellyfinServiceRevision': 9,
    'itemId': _itemId,
    'mediaKey': 'movie:tmdb:603',
  },
  'title': 'The Matrix',
  'contentLength': 4096,
  'contentSha256': '4' * 64,
  'contentType': 'video/mp4',
  'chunkBytes': 16384,
  'downloadedBytes': 4096,
  'state': 'complete',
  'expiresAt': 2000000000,
}, session: fixture.account.session!);

Map<String, Object?> _onlineLease(
  String leaseId,
  int revision, {
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
      'itemId': _itemId,
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
    'expiresAt': 2000000000,
    'restartBehavior': 'terminal_invalid',
  },
};

Map<String, Object?> _watchSnapshot({
  required String leaderId,
  int revision = 1,
  String commandAction = 'play',
  int commandPositionMs = 0,
  String? directiveAction,
  int directivePositionMs = 0,
}) {
  final members = leaderId == adminId ? [adminId] : [leaderId, adminId];
  return {
    'schemaVersion': 1,
    'authority': {
      'schemaVersion': 1,
      'coreId': 'a' * 32,
      'homeId': 'b' * 32,
      'roomId': 'c' * 32,
      'installationId': _installation,
      'installationRevision': 5,
      'snapshotRevision': 7,
      'jellyfinServiceRevision': 9,
      'itemId': _itemId,
      'mediaKey': 'movie:tmdb:603',
    },
    'revision': revision,
    'state': 'active',
    'leaderAccountId': leaderId,
    'expiresAt': 2000000000,
    'toleranceMs': 750,
    'command': {
      'schemaVersion': 1,
      'revision': revision,
      'action': commandAction,
      'positionMs': commandPositionMs,
      'issuedAtMs': 1800000000000,
    },
    'participants': members
        .map(
          (id) => {
            'schemaVersion': 1,
            'accountId': id,
            'revision': revision,
            'isLeader': id == leaderId,
            'connected': true,
            'target': null,
            'playback': null,
            'lastSeenAt': 1800000000,
          },
        )
        .toList(),
    'directive': directiveAction == null
        ? null
        : {
            'schemaVersion': 1,
            'commandRevision': revision,
            'action': directiveAction,
            'positionMs': directivePositionMs,
            'skewMs': 0,
            'toleranceMs': 750,
          },
  };
}

final class _Source extends CoreCatalogPlayerSourcePort {
  final pending = Completer<CoreCatalogPlayerLease?>();
  var opens = 0;
  var retires = 0;
  CoreCatalogPlaybackAuthorization? lastAuthorization;
  CoreCatalogPlayerSourceMode? lastMode;

  @override
  Future<CoreCatalogPlayerLease?> open(
    CoreCatalogPlayerBinding binding, {
    required CoreCatalogPlayerSourceMode mode,
    required CoreCatalogPlaybackAuthorization? authorization,
    required bool Function() current,
  }) {
    opens++;
    lastAuthorization = authorization;
    lastMode = mode;
    return pending.future;
  }

  @override
  void retire() => retires++;
}

final class _LeaseProbe {
  _LeaseProbe(String path) : invalidated = Completer<String>() {
    lease = CoreCatalogPlayerLease(
      playable: Media(path),
      mode: CoreCatalogPlayerSourceMode.offlineVault,
      invalidated: invalidated.future,
      close: () async => closes++,
    );
  }

  final Completer<String> invalidated;
  late CoreCatalogPlayerLease lease;
  var closes = 0;
}

final class _SequencedSource extends CoreCatalogPlayerSourcePort {
  _SequencedSource(this.probes);
  final List<_LeaseProbe> probes;
  var index = 0;
  var retires = 0;

  @override
  Future<CoreCatalogPlayerLease?> open(
    CoreCatalogPlayerBinding binding, {
    required CoreCatalogPlayerSourceMode mode,
    required CoreCatalogPlaybackAuthorization? authorization,
    required bool Function() current,
  }) async => current() ? probes[index++].lease : null;

  @override
  void retire() => retires++;
}

final class _Player extends PlatformPlayer {
  _Player() : super(configuration: const PlayerConfiguration());
  var opens = 0;
  var stops = 0;
  var plays = 0;
  var pauses = 0;
  var failPause = false;
  var failSeek = false;
  Completer<void>? deferredSeek;
  final audioSelections = <String>[];
  final seeks = <Duration>[];

  void emitTracks(Tracks value) => tracksController.add(value);
  void emitPosition(Duration value) => positionController.add(value);
  void emitDuration(Duration value) => durationController.add(value);
  void emitPlaying(bool value) => playingController.add(value);

  @override
  Future<void> open(Playable playable, {bool play = true}) async => opens++;

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> play() async => plays++;

  @override
  Future<void> pause() async {
    pauses++;
    if (failPause) throw StateError('owned pause failure');
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async =>
      audioSelections.add(track.id);

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    if (failSeek) throw StateError('owned seek failure');
    await deferredSeek?.future;
  }
}

final class _Preferences extends JellyfinTrackPreferencesStore {
  @override
  Future<JellyfinTrackPreferenceRecord?> readCurrent({
    required bool Function() isCurrent,
  }) async => isCurrent()
      ? const JellyfinTrackPreferenceRecord(
          audioLanguage: 'tr',
          subtitleLanguage: null,
        )
      : null;
}

final class _Audio extends LocalAudioBridge {
  _Audio() : super(isAndroid: false);
  var stops = 0;
  @override
  Future<void> stopForVideo() async => stops++;
}

void main() {
  test(
    'catalog binding accepts only its exact completed encrypted copy',
    () async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final page = _page();
      final binding = CoreCatalogPlayerBinding.fromCatalog(
        page,
        page.items.single,
      );

      expect(binding.acceptsOfflineManifest(_manifest(fixture)), isTrue);
      expect(
        binding.acceptsOfflineManifest(_manifest(fixture, snapshotRevision: 8)),
        isFalse,
      );
    },
  );

  test('online source binds Core bearer and exact catalog authority', () async {
    final fixture = AdminFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    String? leaseId;
    var revision = 1;
    final capability = CoreCatalogPlaybackCapabilityAdapter(
      fixture.account,
      port: _CapabilityPort(),
      requestId: () => '3' * 32,
      clock: () => fixture.now,
    );
    final profile = (await capability.capture())!;
    fixture.respond = (request) async {
      if (request.url.path.endsWith(
        '/media/playback-quality/${'a' * 32}/${'b' * 32}/observe-item',
      )) {
        return fixture.json(
          _qualityResponse(profile, fixture.now.millisecondsSinceEpoch ~/ 1000),
        );
      }
      if (request.url.path.endsWith('/media/offline/playback-leases')) {
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
          'playbackObservationId',
        });
        expect(body['installationId'], _installation);
        expect(body['itemId'], _itemId);
        expect(body['playbackObservationId'], '4' * 32);
        leaseId = body['requestId']! as String;
        return fixture.json(_onlineLease(leaseId!, revision));
      }
      if (request.url.path.endsWith('/retire')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['expectedRevision'], revision);
        revision++;
        return fixture.json(_onlineLease(leaseId!, revision, state: 'retired'));
      }
      return fixture.defaultResponse(request);
    };
    final page = _page();
    final source = CoreLeaseCatalogPlayerSource(
      fixture.account,
      capability: capability,
      clock: () => fixture.now,
    );
    addTearDown(source.dispose);
    final authorization = await capability.observe(
      CoreCatalogPlayerBinding.fromCatalog(page, page.items.single),
      current: () => true,
    );

    final lease = await source.open(
      CoreCatalogPlayerBinding.fromCatalog(page, page.items.single),
      mode: CoreCatalogPlayerSourceMode.coreLease,
      authorization: authorization,
      current: () => true,
    );

    expect(lease, isNotNull);
    final media = lease!.playable as Media;
    expect(media.uri, contains('/api/v1/media/offline/playback-leases/'));
    expect(media.uri, endsWith('/$leaseId/content'));
    expect(media.httpHeaders?.keys, ['Authorization']);
    expect(media.httpHeaders?['Authorization'], startsWith('Bearer '));
    expect(media.uri, isNot(contains('api_key')));
    source.retire();
    await Future<void>.delayed(Duration.zero);
    expect(
      fixture.calls.where((call) => call.url.path.endsWith('/retire')),
      hasLength(1),
    );
  });

  testWidgets('late source completion cannot reopen after Core logout', (
    tester,
  ) async {
    final fixture = AdminFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/media/playback/segments')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return fixture.json({
          'schemaVersion': 1,
          'requestId': body['requestId'],
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
            'itemId': _itemId,
            'mediaKey': 'movie:tmdb:603',
          },
          'supported': true,
          'reason': 'available',
          'segments': [
            {
              'schemaVersion': 1,
              'kind': 'intro',
              'startSeconds': 10,
              'endSeconds': 75,
            },
          ],
        });
      }
      return fixture.defaultResponse(request);
    };
    final source = _Source();
    final platform = _Player();
    final audio = _Audio();
    final page = _page();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
          coreCatalogPlayerSourceFactoryProvider.overrideWithValue(
            (_) => source,
          ),
          jellyfinPlayerFactoryProvider.overrideWithValue(
            () => Player(platformPlayer: platform),
          ),
          jellyfinVideoSurfaceProvider.overrideWithValue(
            (_) => const SizedBox(key: ValueKey('owned-video-surface')),
          ),
          localAudioBridgeProvider.overrideWithValue(audio),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: CoreCatalogPlayerScreen(page: page, item: page.items.single),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CoreCatalogPlayerScreen), findsOneWidget);
    expect(
      find.byKey(const ValueKey('core-catalog-player-open-online')),
      findsNothing,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('core-catalog-player-open-source')),
    );
    await tester.pump();
    expect(source.opens, 1);

    await fixture.account.signOut();
    await tester.pump();
    source.pending.complete(
      CoreCatalogPlayerLease(
        playable: Media('http://127.0.0.1:49100/media'),
        mode: CoreCatalogPlayerSourceMode.offlineVault,
        close: () async {},
      ),
    );
    await tester.pump();

    expect(source.retires, greaterThanOrEqualTo(1));
    expect(platform.opens, 0);
    expect(platform.stops, greaterThanOrEqualTo(1));
    expect(audio.stops, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Core preference is applied to the actual opened player', (
    tester,
  ) async {
    final fixture = AdminFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/media/playback/segments')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return fixture.json({
          'schemaVersion': 1,
          'requestId': body['requestId'],
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
            'itemId': _itemId,
            'mediaKey': 'movie:tmdb:603',
          },
          'supported': true,
          'reason': 'available',
          'segments': [
            {
              'schemaVersion': 1,
              'kind': 'intro',
              'startSeconds': 10,
              'endSeconds': 75,
            },
          ],
        });
      }
      return fixture.defaultResponse(request);
    };
    final source = _Source();
    source.pending.complete(
      CoreCatalogPlayerLease(
        playable: Media('http://127.0.0.1:49100/media'),
        mode: CoreCatalogPlayerSourceMode.offlineVault,
        close: () async {},
      ),
    );
    final platform = _Player();
    final page = _page();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
          coreCatalogPlayerSourceFactoryProvider.overrideWithValue(
            (_) => source,
          ),
          jellyfinPlayerFactoryProvider.overrideWithValue(
            () => Player(platformPlayer: platform),
          ),
          jellyfinVideoSurfaceProvider.overrideWithValue(
            (_) => const SizedBox(),
          ),
          localAudioBridgeProvider.overrideWithValue(_Audio()),
          jellyfinTrackPreferencesStoreProvider.overrideWithValue(
            _Preferences(),
          ),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: CoreCatalogPlayerScreen(page: page, item: page.items.single),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('core-catalog-player-open-source')),
    );
    await tester.pumpAndSettle();
    platform.emitTracks(
      const Tracks(
        audio: [
          AudioTrack('1', 'English', 'en'),
          AudioTrack('2', 'Turkish', 'tr'),
        ],
      ),
    );
    platform.emitDuration(const Duration(seconds: 100));
    platform.emitPosition(const Duration(seconds: 20));
    await tester.pump();
    await tester.pump();

    expect(platform.opens, 1);
    expect(platform.audioSelections, ['2']);
    final skipSegment = find.byKey(
      const ValueKey('core-catalog-player-skip-segment'),
      skipOffstage: false,
    );
    await _scrollUntilBuilt(tester, skipSegment);
    expect(skipSegment, findsOneWidget);
    await tester.tap(skipSegment);
    await tester.pump();
    expect(platform.seeks, [const Duration(seconds: 75)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'normal online route observes and revalidates before opening the actual player',
    (tester) async {
      _useTallViewport(tester);
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      late CoreCatalogLocalPlaybackProfile profile;
      fixture.respond = (request) async {
        if (request.url.path.contains('/media/playback-quality/')) {
          return fixture.json(
            _qualityResponse(
              profile,
              fixture.now.millisecondsSinceEpoch ~/ 1000,
            ),
          );
        }
        return fixture.defaultResponse(request);
      };
      final source = _Source()
        ..pending.complete(
          CoreCatalogPlayerLease(
            playable: Media('http://127.0.0.1:49100/online'),
            mode: CoreCatalogPlayerSourceMode.coreLease,
            close: () async {},
          ),
        );
      final platform = _Player();
      final capability = CoreCatalogPlaybackCapabilityAdapter(
        fixture.account,
        port: _CapabilityPort(),
        requestId: () => '3' * 32,
        clock: () => fixture.now,
      );
      profile = (await capability.capture())!;
      final page = _page();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverAccountControllerProvider.overrideWithValue(fixture.account),
            coreCatalogOnlinePlaybackAvailableProvider.overrideWithValue(true),
            coreCatalogPlayerSourceFactoryProvider.overrideWithValue(
              (_) => source,
            ),
            coreCatalogPlaybackCapabilityFactoryProvider.overrideWithValue(
              (_) => capability,
            ),
            jellyfinPlayerFactoryProvider.overrideWithValue(
              () => Player(platformPlayer: platform),
            ),
            jellyfinVideoSurfaceProvider.overrideWithValue(
              (_) => const SizedBox(),
            ),
            localAudioBridgeProvider.overrideWithValue(_Audio()),
          ],
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: CoreCatalogPlayerScreen(page: page, item: page.items.single),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(CoreCatalogPlayerScreen), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pump();
      final online = find.byKey(
        const ValueKey('core-catalog-player-open-online'),
      );
      await tester.ensureVisible(online);
      await tester.tap(online);
      await tester.pumpAndSettle();

      expect(source.opens, 1);
      expect(source.lastMode, CoreCatalogPlayerSourceMode.coreLease);
      expect(source.lastAuthorization?.observationId, '4' * 32);
      expect(platform.opens, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'owned controls target the current lease and late old invalidation cannot close its successor',
    (tester) async {
      _useTallViewport(tester);
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      fixture.respond = (request) async => fixture.defaultResponse(request);
      final first = _LeaseProbe('http://127.0.0.1:49100/first');
      final second = _LeaseProbe('http://127.0.0.1:49100/second');
      final source = _SequencedSource([first, second]);
      final platform = _Player();
      final page = _page();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverAccountControllerProvider.overrideWithValue(fixture.account),
            coreCatalogPlayerSourceFactoryProvider.overrideWithValue(
              (_) => source,
            ),
            jellyfinPlayerFactoryProvider.overrideWithValue(
              () => Player(platformPlayer: platform),
            ),
            jellyfinVideoSurfaceProvider.overrideWithValue(
              (_) => const SizedBox(),
            ),
            localAudioBridgeProvider.overrideWithValue(_Audio()),
          ],
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: CoreCatalogPlayerScreen(page: page, item: page.items.single),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pump();
      final open = find.byKey(
        const ValueKey('core-catalog-player-open-source'),
      );
      await tester.ensureVisible(open);
      await tester.tap(open);
      await tester.pumpAndSettle();
      await tester.pump();
      expect(source.index, 1);
      expect(platform.opens, 1);
      expect(first.closes, 0);
      expect(platform.stops, 0);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('core-catalog-player-active')),
        findsOneWidget,
      );
      await tester.drag(find.byType(ListView), const Offset(0, 1000));
      await tester.pump();
      platform.emitDuration(const Duration(minutes: 2));
      platform.emitPosition(const Duration(seconds: 20));
      platform.emitPlaying(true);
      await tester.pump();

      final toggle = find.byKey(
        const ValueKey('core-catalog-player-toggle-playback'),
        skipOffstage: false,
      );
      final forward = find.byKey(
        const ValueKey('core-catalog-player-seek-forward'),
        skipOffstage: false,
      );
      await _scrollUntilBuilt(tester, toggle);
      expect(toggle, findsOneWidget);
      expect(forward, findsOneWidget);
      await tester.tap(toggle);
      await tester.pump();
      expect(platform.pauses, 1);
      platform.emitPlaying(false);
      await tester.pump();
      await tester.tap(toggle);
      await tester.pump();
      expect(platform.plays, 1);
      await _scrollUntilBuilt(tester, forward);
      final delayedSeek = Completer<void>();
      platform.deferredSeek = delayedSeek;
      await tester.tap(forward);
      await tester.pump();
      expect(platform.seeks.last, const Duration(seconds: 30));

      await _scrollUntilBuilt(tester, open);
      await tester.tap(open);
      await tester.pump();
      expect(source.index, 1);
      expect(platform.opens, 1);
      delayedSeek.complete();
      platform.deferredSeek = null;
      await tester.pumpAndSettle();
      expect(first.closes, 1);
      expect(second.closes, 0);
      expect(find.text('00:00 / 00:00'), findsOneWidget);

      first.invalidated.complete('lease_unavailable');
      await tester.pump();
      await tester.pump();
      expect(second.closes, 0);
      await tester.drag(find.byType(ListView), const Offset(0, 1000));
      await tester.pump();
      await _scrollUntilBuilt(
        tester,
        find.byKey(
          const ValueKey('core-catalog-player-toggle-playback'),
          skipOffstage: false,
        ),
      );
      expect(
        find.byKey(
          const ValueKey('core-catalog-player-toggle-playback'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );

      platform.emitDuration(const Duration(minutes: 2));
      platform.emitPosition(const Duration(seconds: 10));
      await tester.pump();
      final hungSeek = Completer<void>();
      platform.deferredSeek = hungSeek;
      await tester.tap(
        find.byKey(
          const ValueKey('core-catalog-player-seek-forward'),
          skipOffstage: false,
        ),
      );
      await tester.pump();
      await _scrollUntilBuilt(tester, open);
      await tester.tap(open);
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();

      expect(source.index, 2);
      expect(platform.opens, 2);
      expect(second.closes, 1);
      expect(
        find.byKey(const ValueKey('core-catalog-player-idle')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leader controls publish exact command for the current lease', (
    tester,
  ) async {
    _useTallViewport(tester);
    final fixture = AdminFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final commands = <Map<String, dynamic>>[];
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/media/playback/segments')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return fixture.json({
          'schemaVersion': 1,
          'requestId': body['requestId'],
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
            'itemId': _itemId,
            'mediaKey': 'movie:tmdb:603',
          },
          'supported': true,
          'reason': 'available',
          'segments': [
            {
              'schemaVersion': 1,
              'kind': 'intro',
              'startSeconds': 10,
              'endSeconds': 75,
            },
          ],
        });
      }
      if (request.url.path.endsWith('/media/catalog/target')) {
        return fixture.json({
          'schemaVersion': 1,
          'installationId': _installation,
          'installationRevision': 5,
          'snapshotRevision': 7,
          'jellyfinServiceRevision': 9,
        });
      }
      if (request.url.path.endsWith('/media/catalog/resolve')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return fixture.json({
          'requestId': body['requestId'],
          'catalog': {
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
                'itemId': _itemId,
                'mediaKey': 'movie:tmdb:603',
                'title': 'The Matrix',
                'mediaKind': 'movie',
                'runtimeSeconds': 8160,
              },
            ],
          },
        });
      }
      if (request.url.path.endsWith('/media/watch-parties')) {
        return fixture.json({
          'snapshot': _watchSnapshot(leaderId: adminId),
          'inviteCode': 'd' * 32,
        });
      }
      if (request.url.path.endsWith('/commands')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        commands.add(body);
        return fixture.json({
          'snapshot': _watchSnapshot(
            leaderId: adminId,
            revision: commands.length + 1,
            commandAction: body['action']! as String,
            commandPositionMs: body['positionMs']! as int,
          ),
        });
      }
      return fixture.defaultResponse(request);
    };
    final source = _Source()
      ..pending.complete(
        CoreCatalogPlayerLease(
          playable: Media('http://127.0.0.1:49100/media'),
          mode: CoreCatalogPlayerSourceMode.offlineVault,
          close: () async {},
        ),
      );
    final platform = _Player();
    final page = _page();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
          coreCatalogPlayerSourceFactoryProvider.overrideWithValue(
            (_) => source,
          ),
          jellyfinPlayerFactoryProvider.overrideWithValue(
            () => Player(platformPlayer: platform),
          ),
          jellyfinVideoSurfaceProvider.overrideWithValue(
            (_) => const SizedBox(),
          ),
          localAudioBridgeProvider.overrideWithValue(_Audio()),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: CoreCatalogPlayerScreen(page: page, item: page.items.single),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();
    final open = find.byKey(const ValueKey('core-catalog-player-open-source'));
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    await tester.pump();
    expect(source.opens, 1);
    expect(platform.opens, 1);
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ListView), const Offset(0, 1000));
    await tester.pump();
    final create = find.byKey(
      const ValueKey('core-catalog-player-watch-party-create'),
      skipOffstage: false,
    );
    await _scrollUntilBuilt(tester, create);
    await tester.tap(create);
    await tester.pump();
    await tester.pump();
    platform.emitPosition(const Duration(seconds: 20));
    platform.emitDuration(const Duration(minutes: 2));
    platform.emitPlaying(true);
    await tester.pump();
    final toggle = find.byKey(
      const ValueKey('core-catalog-player-toggle-playback'),
      skipOffstage: false,
    );
    await tester.ensureVisible(toggle);
    platform.failPause = true;
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump();

    expect(platform.pauses, 1);
    expect(commands, isEmpty);
    platform.failPause = false;
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump();

    expect(platform.pauses, 2);
    expect(commands, hasLength(1));
    expect(commands.single['action'], 'pause');
    expect(commands.single['positionMs'], 20000);
    platform.failSeek = true;
    final forward = find.byKey(
      const ValueKey('core-catalog-player-seek-forward'),
      skipOffstage: false,
    );
    await tester.tap(forward);
    await tester.pump();
    await tester.pump();
    expect(commands, hasLength(1));
    final skip = find.byKey(
      const ValueKey('core-catalog-player-skip-segment'),
      skipOffstage: false,
    );
    await _scrollUntilBuilt(tester, skip);
    await tester.tap(skip);
    await tester.pump();
    await tester.pump();
    expect(commands, hasLength(1));
    platform.failSeek = false;
    await tester.tap(skip);
    await tester.pump();
    await tester.pump();
    expect(commands, hasLength(2));
    expect(commands.last['action'], 'play');
    expect(commands.last['positionMs'], 75000);
    expect(platform.seeks.last, const Duration(seconds: 75));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'follower pause directive seeks first and never echoes a command',
    (tester) async {
      _useTallViewport(tester);
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      var commands = 0;
      fixture.respond = (request) async {
        if (request.url.path.endsWith('/media/playback/segments')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return fixture.json({
            'schemaVersion': 1,
            'requestId': body['requestId'],
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
              'itemId': _itemId,
              'mediaKey': 'movie:tmdb:603',
            },
            'supported': true,
            'reason': 'available',
            'segments': [
              {
                'schemaVersion': 1,
                'kind': 'intro',
                'startSeconds': 10,
                'endSeconds': 75,
              },
            ],
          });
        }
        if (request.url.path.endsWith('/join')) {
          return fixture.json({'snapshot': _watchSnapshot(leaderId: 'e' * 32)});
        }
        if (request.url.path.endsWith('/reports')) {
          return fixture.json({
            'snapshot': _watchSnapshot(
              leaderId: 'e' * 32,
              revision: 2,
              commandAction: 'pause',
              commandPositionMs: 45000,
              directiveAction: 'pause',
              directivePositionMs: 45000,
            ),
          });
        }
        if (request.url.path.endsWith('/commands')) commands++;
        return fixture.defaultResponse(request);
      };
      final source = _Source()
        ..pending.complete(
          CoreCatalogPlayerLease(
            playable: Media('http://127.0.0.1:49100/media'),
            mode: CoreCatalogPlayerSourceMode.offlineVault,
            close: () async {},
          ),
        );
      final platform = _Player();
      final page = _page();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverAccountControllerProvider.overrideWithValue(fixture.account),
            coreCatalogPlayerSourceFactoryProvider.overrideWithValue(
              (_) => source,
            ),
            jellyfinPlayerFactoryProvider.overrideWithValue(
              () => Player(platformPlayer: platform),
            ),
            jellyfinVideoSurfaceProvider.overrideWithValue(
              (_) => const SizedBox(),
            ),
            localAudioBridgeProvider.overrideWithValue(_Audio()),
          ],
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: CoreCatalogPlayerScreen(page: page, item: page.items.single),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pump();
      final open = find.byKey(
        const ValueKey('core-catalog-player-open-source'),
      );
      await tester.ensureVisible(open);
      await tester.tap(open);
      await tester.pumpAndSettle();
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, 1000));
      await tester.pump();
      final join = find.byKey(
        const ValueKey('core-catalog-player-watch-party-join'),
        skipOffstage: false,
      );
      await _scrollUntilBuilt(tester, join);
      await tester.tap(join);
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('core-catalog-player-watch-party-code')),
        '${'c' * 32}:1:$_itemId:${'d' * 32}',
      );
      await tester.tap(find.byType(CupertinoDialogAction).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump();
      platform.emitDuration(const Duration(seconds: 100));
      platform.emitPosition(const Duration(seconds: 20));
      await tester.pump();

      expect(platform.seeks, contains(const Duration(seconds: 45)));
      expect(platform.pauses, 1);
      expect(commands, 0);
      final control = tester.widget<CupertinoButton>(
        find.byKey(
          const ValueKey('core-catalog-player-toggle-playback'),
          skipOffstage: false,
        ),
      );
      expect(control.onPressed, isNull);
      final skip = find.byKey(
        const ValueKey('core-catalog-player-skip-segment'),
        skipOffstage: false,
      );
      await _scrollUntilBuilt(tester, skip);
      final skipButton = tester.widget<CupertinoButton>(skip);
      expect(skipButton.onPressed, isNull);
      await tester.tap(skip, warnIfMissed: false);
      await tester.pump();
      expect(platform.seeks, [const Duration(seconds: 45)]);
      expect(commands, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
