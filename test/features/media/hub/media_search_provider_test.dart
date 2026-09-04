import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/arr/data/arr_client.dart';
import 'package:larenor/features/media/arr/data/arr_config.dart';
import 'package:larenor/features/media/arr/providers/radarr_providers.dart';
import 'package:larenor/features/media/arr/providers/sonarr_providers.dart';
import 'package:larenor/features/media/hub/domain/media_identity.dart';
import 'package:larenor/features/media/hub/domain/media_library_index.dart';
import 'package:larenor/features/media/hub/providers/media_catalog_providers.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';

void main() {
  test('unified search works for a Radarr-only installation', () async {
    final client = ArrClient(
      config: const ArrConfig(baseUrl: 'http://radarr.test', apiKey: 'fixture'),
      resourcePath: 'movie',
      idFieldName: 'tmdbId',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/api/v3/movie/lookup');
        expect(request.url.queryParameters['term'], 'Matrix');
        return http.Response(
          '[{"title":"The Matrix","tmdbId":603,"year":1999}]',
          200,
        );
      }),
    );
    addTearDown(client.dispose);
    final container = ProviderContainer(
      overrides: [
        jellyfinClientProvider.overrideWith((ref) => null),
        jellyseerrClientProvider.overrideWith((ref) => null),
        sonarrClientProvider.overrideWith((ref) => null),
        radarrClientProvider.overrideWith((ref) => client),
        mediaLibraryIndexProvider.overrideWith(
          (ref) async => MediaLibraryIndex.empty,
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      mediaSearchProvider('Matrix'),
      (_, _) {},
    );
    addTearDown(subscription.close);
    final results = await container.read(mediaSearchProvider('Matrix').future);
    expect(results, hasLength(1));
    expect(results.single.identity.kind, MediaKind.movie);
    expect(results.single.identity.tmdbId, 603);
    expect(results.single.title, 'The Matrix');
  });
}
