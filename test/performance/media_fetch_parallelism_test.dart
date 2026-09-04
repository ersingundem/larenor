import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/arr/data/arr_client.dart';
import 'package:larenor/features/media/arr/data/arr_config.dart';
import 'package:larenor/features/media/arr/providers/radarr_providers.dart';
import 'package:larenor/features/media/arr/providers/sonarr_providers.dart';
import 'package:larenor/features/media/hub/domain/media_library_index.dart';
import 'package:larenor/features/media/hub/providers/media_catalog_providers.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';

void main() {
  test('search starts before a slow library index completes', () async {
    final index = Completer<MediaLibraryIndex>();
    var searchStarted = false;
    final client = ArrClient(
      config: const ArrConfig(baseUrl: 'http://radarr.test', apiKey: 'fixture'),
      resourcePath: 'movie',
      idFieldName: 'tmdbId',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/api/v3/movie/lookup');
        searchStarted = true;
        return http.Response('[{"title":"The Matrix","tmdbId":603}]', 200);
      }),
    );
    final container = ProviderContainer(
      overrides: [
        jellyfinClientProvider.overrideWith((_) => null),
        jellyseerrClientProvider.overrideWith((_) => null),
        sonarrClientProvider.overrideWith((_) => null),
        radarrClientProvider.overrideWith((_) => client),
        mediaLibraryIndexProvider.overrideWith((_) => index.future),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(client.dispose);
    container.listen(mediaSearchProvider('Matrix'), (_, _) {});
    final results = container.read(mediaSearchProvider('Matrix').future);
    await container.pump();
    await Future<void>.delayed(Duration.zero);
    expect(searchStarted, isTrue);
    index.complete(MediaLibraryIndex.empty);
    expect((await results).single.title, 'The Matrix');
  });

  test('library and hub share one queue fetch per refresh', () async {
    var queueReads = 0;
    final library = Completer<http.Response>();
    var calendarStarted = false;
    final client = ArrClient(
      config: const ArrConfig(baseUrl: 'http://radarr.test', apiKey: 'fixture'),
      resourcePath: 'movie',
      idFieldName: 'tmdbId',
      httpClient: MockClient((request) async {
        switch (request.url.path) {
          case '/api/v3/movie':
            return library.future;
          case '/api/v3/calendar':
            calendarStarted = true;
            return http.Response('[]', 200);
          case '/api/v3/queue':
            queueReads++;
            return http.Response(
              jsonEncode({
                'records': [
                  {
                    'id': 1,
                    'movieId': 2,
                    'title': 'The Matrix',
                    'size': 100,
                    'sizeleft': 50,
                    'movie': {'tmdbId': 603},
                  },
                ],
              }),
              200,
            );
          default:
            throw StateError('Unexpected path: ${request.url.path}');
        }
      }),
    );
    final container = ProviderContainer(
      overrides: [
        jellyfinClientProvider.overrideWith((_) => null),
        jellyseerrClientProvider.overrideWith((_) => null),
        sonarrClientProvider.overrideWith((_) => null),
        radarrClientProvider.overrideWith((_) => client),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(client.dispose);
    container.listen(mediaHubRowsProvider, (_, _) {});
    final rowsFuture = container.read(mediaHubRowsProvider.future);
    await container.pump();
    await Future<void>.delayed(Duration.zero);
    expect(calendarStarted, isTrue);
    expect(queueReads, 1);
    library.complete(http.Response('[]', 200));
    final rows = await rowsFuture;
    expect(rows.single.id, MediaRowId.downloading);
    expect(rows.single.titles.single.downloadProgress, 0.5);
    expect(queueReads, 1);

    container.invalidate(radarrQueueProvider);
    container.invalidate(sonarrQueueProvider);
    container.invalidate(mediaLibraryIndexProvider);
    container.invalidate(mediaHubRowsProvider);
    await container.read(mediaHubRowsProvider.future);
    expect(
      queueReads,
      2,
      reason: 'An explicit refresh must read fresh progress',
    );
  });
}
