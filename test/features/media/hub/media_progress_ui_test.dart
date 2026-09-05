import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/media/arr/providers/radarr_providers.dart';
import 'package:larenor/features/media/arr/providers/sonarr_providers.dart';
import 'package:larenor/features/media/hub/domain/media_identity.dart';
import 'package:larenor/features/media/hub/domain/media_library_index.dart';
import 'package:larenor/features/media/hub/domain/media_read_result.dart';
import 'package:larenor/features/media/hub/domain/media_title.dart';
import 'package:larenor/features/media/hub/presentation/media_title_detail_screen.dart';
import 'package:larenor/features/media/hub/presentation/widgets/media_progress_card.dart';
import 'package:larenor/features/media/hub/providers/media_catalog_providers.dart';
import 'package:larenor/features/media/hub/providers/media_details_providers.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_client.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/data/models/jellyfin_item.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_series_screen.dart';
import 'package:larenor/features/media/jellyfin/presentation/player/jellyfin_player_screen.dart';
import 'package:larenor/features/media/movie_night/presentation/movie_night_launcher.dart';
import 'package:media_kit/media_kit.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_client.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_config.dart';
import 'package:larenor/features/media/jellyseerr/data/models/jellyseerr_details.dart';
import 'package:larenor/features/media/jellyseerr/data/models/jellyseerr_result.dart';
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _identity = MediaIdentity(kind: MediaKind.movie, tmdbId: 1);
const _seed = MediaTitle(
  identity: _identity,
  title: 'Orbit',
  availability: MediaAvailability.notAvailable,
);
const _series = JellyfinItem(
  id: 'series',
  name: 'Family series',
  type: 'Series',
  providerIds: {'Tmdb': '2'},
);
const _jfConfig = JellyfinConfig(
  baseUrl: 'http://jf.invalid',
  userId: 'user',
  accessToken: 'test',
  deviceId: 'test-device',
);

class _Connection extends JellyfinConnection {
  @override
  Future<JellyfinConfig?> build() async => _jfConfig;
  void change() => state = const AsyncData(
    JellyfinConfig(
      baseUrl: 'http://new.invalid',
      userId: 'different',
      accessToken: 'test-new',
      deviceId: 'test-device',
    ),
  );
}

class _FakePlayer extends PlatformPlayer {
  _FakePlayer() : super(configuration: const PlayerConfiguration());
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
}

class _Harness {
  JellyfinClient? jellyfin;
  Player Function()? playerFactory;
  JellyseerrClient? seerr;
  JellyseerrDetails? details;
  MediaLibraryIndex index = MediaLibraryIndex.empty;
  final connection = _Connection();
  late GoRouter router;
  late ProviderContainer container;
  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(600, 1100),
    double scale = 1,
    Locale locale = const Locale('en'),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      retry: (count, error) => null,
      overrides: [
        jellyfinConnectionProvider.overrideWith(() => connection),
        jellyfinClientProvider.overrideWith((ref) => jellyfin),
        if (playerFactory != null)
          jellyfinPlayerFactoryProvider.overrideWithValue(playerFactory!),
        jellyseerrClientProvider.overrideWith((ref) => seerr),
        sonarrClientProvider.overrideWith((ref) => null),
        radarrClientProvider.overrideWith((ref) => null),
        mediaCatalogueDetailsProvider.overrideWith(
          (ref, identity) async => details,
        ),
        mediaLibraryIndexProvider.overrideWith((ref) async => index),
        mediaHubRowsProvider.overrideWith((ref) async => []),
        jellyseerrMyRequestsProvider.overrideWith((ref) async => []),
      ],
    );
    await container.read(jellyfinConnectionProvider.future);
    router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => child),
        GoRoute(
          path: '/system/:service',
          builder: (_, state) => CupertinoPageScaffold(
            child: Text('Service ${state.pathParameters['service']}'),
          ),
        ),
      ],
    );
    addTearDown(() {
      router.dispose();
      container.dispose();
      jellyfin?.dispose();
      seerr?.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp.router(
          routerConfig: router,
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

JellyfinClient _jf(Future<http.Response> Function(http.Request) response) =>
    JellyfinClient(config: _jfConfig, httpClient: MockClient(response));
http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);
JellyseerrDetails _catalogue({
  bool tv = false,
  int status = 1,
  List<JellyseerrSeasonSummary> seasons = const [],
}) => JellyseerrDetails(
  result: JellyseerrResult(
    id: tv ? 2 : 1,
    mediaType: tv ? 'tv' : 'movie',
    title: tv ? 'Family series' : 'Orbit',
    mediaInfo: JellyseerrMediaInfo(status: status),
  ),
  seasons: seasons,
);

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  for (final stage in [
    MediaAvailability.queued,
    MediaAvailability.paused,
    MediaAvailability.importing,
    MediaAvailability.partiallyAvailable,
    MediaAvailability.available,
    MediaAvailability.failed,
    MediaAvailability.unknown,
  ]) {
    testWidgets(
      'progress card labels ${stage.name} without promising playback',
      (tester) async {
        final harness = _Harness();
        await harness.mount(
          tester,
          CupertinoPageScaffold(
            child: SafeArea(
              child: MediaProgressCard(
                title: _seed.copyWith(availability: stage),
              ),
            ),
          ),
        );
        final context = tester.element(find.byType(MediaProgressCard));
        expect(
          find.text(
            mediaAvailabilityLabel(AppLocalizations.of(context), stage),
          ),
          findsOneWidget,
        );
        expect(find.text('Play'), findsNothing);
      },
    );
  }

  testWidgets(
    'playable content and an independent unknown-progress transfer coexist',
    (tester) async {
      final harness = _Harness();
      await harness.mount(
        tester,
        CupertinoPageScaffold(
          child: SafeArea(
            child: MediaProgressCard(
              title: _seed.copyWith(
                availability: MediaAvailability.inLibrary,
                jellyfinItemId: 'movie',
                transfers: const [
                  MediaTransferProgress(
                    id: 'queue-1',
                    source: IntegrationId.radarr,
                    stage: MediaAvailability.downloading,
                  ),
                ],
                readIssues: const [
                  MediaReadIssue(
                    MediaReadKey(
                      IntegrationId.bazarr,
                      MediaReadOperation.library,
                    ),
                    HealthFailure.permission,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('Progress is not reported.'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
      expect(find.text('Radarr · Downloading'), findsOneWidget);
      await _tap(tester, 'media-open-radarr');
      expect(find.text('Service radarr'), findsOneWidget);
    },
  );

  testWidgets(
    'read-only lookup loads current details without promising playback',
    (tester) async {
      final harness = _Harness();
      final paths = <String>[];
      harness.jellyfin = _jf((request) async {
        paths.add(request.url.path);
        return _json({
          'Id': 'lookup',
          'Name': 'Verified Orbit',
          'Type': 'Movie',
          'ProviderIds': {'Tmdb': '1'},
        });
      });
      await harness.mount(
        tester,
        MediaTitleDetailScreen(
          title: _seed.copyWith(jellyfinLookupId: 'lookup'),
        ),
      );
      expect(find.text('Verified Orbit'), findsWidgets);
      expect(find.byKey(const ValueKey('media-primary-play')), findsNothing);
      expect(paths, hasLength(1));
      expect(paths.single, endsWith('/Items/lookup'));
      expect(paths.any((path) => path.contains('PlaybackInfo')), isFalse);
    },
  );

  testWidgets('stale route item ID alone never offers Play', (tester) async {
    final harness = _Harness();
    final paths = <String>[];
    harness.jellyfin = _jf((request) async {
      paths.add(request.url.path);
      return http.Response('private', 404);
    });
    await harness.mount(
      tester,
      MediaTitleDetailScreen(
        title: _seed.copyWith(
          availability: MediaAvailability.inLibrary,
          jellyfinItemId: 'old-id',
        ),
      ),
    );
    expect(find.byKey(const ValueKey('media-primary-play')), findsNothing);
    expect(paths.any((path) => path.contains('PlaybackInfo')), isFalse);
    expect(find.textContaining('private'), findsNothing);
  });

  testWidgets(
    'request sends one POST and reports acceptance instead of playback',
    (tester) async {
      final harness = _Harness();
      harness.details = _catalogue();
      final pending = Completer<http.Response>();
      final requests = <http.Request>[];
      harness.seerr = JellyseerrClient(
        config: const JellyseerrConfig(
          baseUrl: 'http://seerr.invalid',
          apiKey: 'test',
        ),
        httpClient: MockClient((request) async {
          requests.add(request);
          return pending.future;
        }),
      );
      await harness.mount(tester, const MediaTitleDetailScreen(title: _seed));
      final request = tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('media-primary-request')),
          )
          .onPressed!;
      request();
      request();
      await tester.pump();
      expect(requests.where((request) => request.method == 'POST').length, 1);
      pending.complete(_json({'id': 1}));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'The request was accepted. Availability will be checked again.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('media-primary-play')), findsNothing);
    },
  );

  testWidgets(
    'TV requests require explicitly selected seasons and preserve specials zero',
    (tester) async {
      final harness = _Harness();
      harness.details = _catalogue(
        tv: true,
        seasons: const [
          JellyseerrSeasonSummary(
            seasonNumber: 0,
            name: 'Specials',
            episodeCount: 2,
          ),
          JellyseerrSeasonSummary(
            seasonNumber: 1,
            name: 'Season 1',
            episodeCount: 8,
          ),
        ],
      );
      final requests = <http.Request>[];
      harness.seerr = JellyseerrClient(
        config: const JellyseerrConfig(
          baseUrl: 'http://seerr.invalid',
          apiKey: 'test',
        ),
        httpClient: MockClient((request) async {
          requests.add(request);
          return _json({'id': 1});
        }),
      );
      await harness.mount(
        tester,
        const MediaTitleDetailScreen(
          title: MediaTitle(
            identity: MediaIdentity(kind: MediaKind.tv, tmdbId: 2),
            title: 'Family series',
            availability: MediaAvailability.notAvailable,
          ),
        ),
      );
      await _tap(tester, 'media-primary-request');
      expect(requests, isEmpty);
      expect(
        tester
            .widget<CupertinoButton>(
              find.byKey(const ValueKey('media-confirm-request')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byType(CupertinoCheckbox).first);
      await tester.pump();
      await _tap(tester, 'media-confirm-request');
      expect(jsonDecode(requests.single.body)['seasons'], [0]);
    },
  );

  testWidgets(
    'late request failure after account replacement cannot update the new page',
    (tester) async {
      final harness = _Harness();
      harness.details = _catalogue();
      final pending = Completer<http.Response>();
      var posts = 0;
      harness.seerr = JellyseerrClient(
        config: const JellyseerrConfig(
          baseUrl: 'http://seerr.invalid',
          apiKey: 'test',
        ),
        httpClient: MockClient((request) async {
          posts++;
          return pending.future;
        }),
      );
      await harness.mount(tester, const MediaTitleDetailScreen(title: _seed));
      final callback = tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('media-primary-request')),
          )
          .onPressed!;
      callback();
      await tester.pump();
      harness.connection.change();
      await tester.pump();
      pending.complete(http.Response('private-backend-detail', 403));
      await tester.pumpAndSettle();
      callback();
      await tester.pumpAndSettle();
      expect(posts, 1);
      expect(find.text('Orbit'), findsNothing);
      expect(find.textContaining('private-backend-detail'), findsNothing);
      expect(
        find.text('The media connection changed. Open this title again.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'series keeps missing, unknown and unaired episodes without offering play',
    (tester) async {
      final harness = _Harness();
      final requests = <http.Request>[];
      harness.jellyfin = _jf((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/Seasons')) {
          return _json({
            'Items': [
              {
                'Id': 'season-0',
                'Name': 'Specials',
                'Type': 'Season',
                'IndexNumber': 0,
              },
            ],
          });
        }
        return _json({
          'Items': [
            {
              'Id': 'ready',
              'Name': 'Ready episode',
              'Type': 'Episode',
              'LocationType': 'FileSystem',
              'PlayAccess': 'Full',
              'ParentIndexNumber': 0,
              'IndexNumber': 1,
            },
            {
              'Id': 'missing',
              'Name': 'Missing episode',
              'Type': 'Episode',
              'LocationType': 'Virtual',
            },
            {'Id': 'unknown', 'Name': 'Unknown episode', 'Type': 'Episode'},
            {
              'Id': 'unaired',
              'Name': 'Future episode',
              'Type': 'Episode',
              'LocationType': 'Virtual',
              'PremiereDate': '2099-01-01T00:00:00Z',
            },
          ],
        });
      });
      await harness.mount(tester, const JellyfinSeriesScreen(series: _series));
      expect(
        requests.every(
          (request) => !request.url.queryParameters.containsKey('IsMissing'),
        ),
        isTrue,
      );
      for (final id in ['missing', 'unknown', 'unaired']) {
        final finder = find.byKey(ValueKey('media-episode-$id'));
        await tester.ensureVisible(finder);
        expect(tester.widget<CupertinoButton>(finder).onPressed, isNull);
      }
      expect(find.text('Not released yet'), findsOneWidget);
      expect(find.text('Status not verified'), findsOneWidget);
      expect(requests.every((request) => request.method == 'GET'), isTrue);
    },
  );

  testWidgets(
    'catalogue-only seasons remain visible with explicit unknown Jellyfin coverage',
    (tester) async {
      final harness = _Harness();
      var episodeReads = 0;
      harness.jellyfin = _jf((request) async {
        if (request.url.path.endsWith('/Seasons')) {
          return _json({
            'Items': [
              {
                'Id': 'season-1',
                'Name': 'Season 1',
                'Type': 'Season',
                'IndexNumber': 1,
              },
            ],
          });
        }
        episodeReads++;
        return _json({'Items': []});
      });
      await harness.mount(
        tester,
        const JellyfinSeriesScreen(
          series: _series,
          catalogueSeasons: [
            JellyseerrSeasonSummary(seasonNumber: 1, episodeCount: 8),
            JellyseerrSeasonSummary(seasonNumber: 2, episodeCount: 10),
          ],
        ),
      );
      await _tap(tester, 'media-season-number:2');
      expect(
        find.text('This season is not listed by Jellyfin.'),
        findsOneWidget,
      );
      expect(find.text('10 episodes in catalogue'), findsOneWidget);
      expect(episodeReads, 1);
    },
  );

  testWidgets(
    'season refresh rereads metadata and a pending prior-account episode cannot appear',
    (tester) async {
      final harness = _Harness();
      var seasonReads = 0;
      final episodes = Completer<http.Response>();
      harness.jellyfin = _jf((request) async {
        if (request.url.path.endsWith('/Seasons')) {
          seasonReads++;
          return _json({'Items': []});
        }
        return seasonReads == 1 ? _json({'Items': []}) : episodes.future;
      });
      await harness.mount(tester, const JellyfinSeriesScreen(series: _series));
      await tester.tap(find.text('Refresh'));
      await tester.pump();
      expect(seasonReads, 2);
      harness.connection.change();
      await tester.pump();
      episodes.complete(
        _json({
          'Items': [
            {
              'Id': 'old-episode',
              'Name': 'Private old episode',
              'Type': 'Episode',
            },
          ],
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private old episode'), findsNothing);
      expect(find.text('Family series'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'movie-night binding stays mounted across real player route and returns true',
    (tester) async {
      final harness = _Harness();
      final player = _FakePlayer();
      harness.playerFactory = () => Player(platformPlayer: player);
      final pendingPlayback = Completer<http.Response>();
      harness.jellyfin = _jf((request) async {
        if (request.url.path.contains('PlaybackInfo')) {
          return pendingPlayback.future;
        }
        return _json({
          'Id': 'movie',
          'Name': 'Orbit',
          'Type': 'Movie',
          'ProviderIds': {'Tmdb': '1'},
          'LocationType': 'FileSystem',
          'PlayAccess': 'Full',
        });
      });
      await harness.mount(
        tester,
        MediaTitleDetailScreen(title: _seed.copyWith(jellyfinItemId: 'movie')),
      );
      final launcher = tester.widget<MovieNightLauncher>(
        find.byType(MovieNightLauncher),
      );
      final initialState = tester.state(find.byType(MovieNightLauncher));
      expect(launcher.enabled, isTrue);
      expect(launcher.isPlaybackCurrent(), isTrue);
      final opening = launcher.onPlay();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(JellyfinPlayerScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(JellyfinPlayerScreen))).pop();
      pendingPlayback.complete(_json({'ErrorCode': 'NotAllowed'}));
      await tester.pumpAndSettle();
      expect(await opening, isTrue);
      expect(
        identical(initialState, tester.state(find.byType(MovieNightLauncher))),
        isTrue,
      );
      expect(launcher.isPlaybackCurrent(), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('replacing the route title expires the former movie-night flow', (
    tester,
  ) async {
    final harness = _Harness();
    final title = ValueNotifier(_seed);
    addTearDown(title.dispose);
    await harness.mount(
      tester,
      ValueListenableBuilder(
        valueListenable: title,
        builder: (_, value, _) => MediaTitleDetailScreen(title: value),
      ),
    );
    final previous = tester.widget<MovieNightLauncher>(
      find.byType(MovieNightLauncher),
    );
    final previousState = tester.state(find.byType(MovieNightLauncher));
    title.value = _seed.copyWith(
      identity: const MediaIdentity(kind: MediaKind.movie, tmdbId: 99),
      title: 'Another film',
    );
    await tester.pumpAndSettle();
    expect(previous.isPlaybackCurrent(), isFalse);
    expect(
      identical(previousState, tester.state(find.byType(MovieNightLauncher))),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 900), const Size(1100, 900)]) {
    testWidgets(
      'progress and season controls fit ${size.width}px Turkish text at 2x',
      (tester) async {
        final harness = _Harness();
        harness.jellyfin = _jf(
          (request) async => _json({
            'Items': request.url.path.endsWith('/Seasons')
                ? [
                    {
                      'Id': 'season-0',
                      'Name': 'Uzun özel bölümler sezonu',
                      'Type': 'Season',
                      'IndexNumber': 0,
                    },
                  ]
                : [
                    {
                      'Id': 'episode',
                      'Name': 'Uzun bir bölüm başlığı',
                      'Type': 'Episode',
                      'LocationType': 'Virtual',
                    },
                  ],
          }),
        );
        await harness.mount(
          tester,
          const JellyfinSeriesScreen(series: _series),
          size: size,
          scale: 2,
          locale: const Locale('tr'),
        );
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
