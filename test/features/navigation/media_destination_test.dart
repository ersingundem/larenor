import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/data/media_api_exception.dart';
import 'package:larenor/features/media/hub/domain/media_library_index.dart';
import 'package:larenor/features/media/hub/providers/media_catalog_providers.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_client.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_client.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_config.dart';
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';
import 'package:larenor/features/navigation/providers/media_destination_provider.dart';

final _currentClient = NotifierProvider<_CurrentClient, JellyseerrClient?>(
  _CurrentClient.new,
);

class _CurrentClient extends Notifier<JellyseerrClient?> {
  @override
  JellyseerrClient? build() => null;
  void setClient(JellyseerrClient? value) => state = value;
}

JellyseerrClient _seerr(Future<http.Response> Function(http.Request) handle) =>
    JellyseerrClient(
      config: const JellyseerrConfig(
        baseUrl: 'https://catalogue.test',
        apiKey: 'fixture',
      ),
      httpClient: MockClient(handle),
    );

http.Response _movie(String title, {int id = 42}) =>
    http.Response(jsonEncode({'id': id, 'title': title}), 200);

ProviderContainer _container({
  JellyseerrClient? seerr,
  JellyfinClient? jellyfin,
  bool dynamicClient = false,
  bool rejectLibrary = false,
}) {
  final container = ProviderContainer(
    overrides: [
      jellyfinClientProvider.overrideWith((_) => jellyfin),
      jellyseerrClientProvider.overrideWith(
        (ref) => dynamicClient ? ref.watch(_currentClient) : seerr,
      ),
      mediaLibraryIndexProvider.overrideWith((_) async {
        if (rejectLibrary) {
          throw StateError(
            'Direct metadata must not require full library reads',
          );
        }
        return MediaLibraryIndex.empty;
      }),
      mediaHubRowsProvider.overrideWith(
        (_) async =>
            throw StateError('Do not scan discover feeds for deep links'),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('lookup-only movie resolves with one fresh read and never negotiates playback', () async {
    final requests = <http.Request>[];
    final client = JellyfinClient(
      config: const JellyfinConfig(
        baseUrl: 'https://library.test',
        userId: 'viewer',
        accessToken: 'fixture',
        deviceId: 'test',
      ),
      httpClient: MockClient((request) async {
        requests.add(request);
        expect(request.method, 'GET');
        expect(request.url.path, '/Users/viewer/Items/unknown');
        return http.Response(
          jsonEncode({
            'Id': 'unknown',
            'Name': 'Unverified local movie',
            'Type': 'Movie',
          }),
          200,
        );
      }),
    );
    addTearDown(client.dispose);
    final container = _container(jellyfin: client, rejectLibrary: true);
    final title = await container.read(
      mediaDestinationProvider(
        Uri.parse('/media/title?kind=movie&jellyfin=unknown'),
      ).future,
    );
    expect(title?.title, 'Unverified local movie');
    expect(title?.jellyfinLookupId, 'unknown');
    expect(title?.jellyfinItemId, isNull);
    expect(title?.isPlayable, isFalse);
    expect(requests, hasLength(1));
  });
  final uri = Uri.parse('/media/title?kind=movie&tmdb=42');
  test(
    'off-feed title resolves by direct ID without scanning library or discover',
    () async {
      final paths = <String>[];
      final client = _seerr((request) async {
        paths.add(request.url.path);
        return _movie('Outside feed');
      });
      addTearDown(client.dispose);
      final container = _container(seerr: client, rejectLibrary: true);
      final title = await container.read(mediaDestinationProvider(uri).future);
      expect(title?.title, 'Outside feed');
      expect(paths, ['/api/v1/movie/42']);
      expect(container.exists(mediaLibraryIndexProvider), isFalse);
      expect(container.exists(mediaHubRowsProvider), isFalse);
    },
  );

  test(
    'late prior-account response cannot replace new account metadata',
    () async {
      final late = Completer<http.Response>();
      final started = Completer<void>();
      final first = _seerr((_) {
        started.complete();
        return late.future;
      });
      final second = _seerr((_) async => _movie('Current account'));
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final container = _container(dynamicClient: true);
      container.read(_currentClient.notifier).setClient(first);
      container.listen(mediaDestinationProvider(uri), (_, _) {});
      await started.future;
      container.read(_currentClient.notifier).setClient(second);
      final title = await container.read(mediaDestinationProvider(uri).future);
      expect(title?.title, 'Current account');
      late.complete(_movie('Old account'));
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(mediaDestinationProvider(uri)).value?.title,
        'Current account',
      );
    },
  );

  test(
    'catalogue permission failure is not presented as missing title',
    () async {
      final client = _seerr((_) async => http.Response('{}', 403));
      addTearDown(client.dispose);
      final container = _container(seerr: client);
      await expectLater(
        container.read(mediaDestinationProvider(uri).future),
        throwsA(
          isA<MediaApiException>().having((e) => e.statusCode, 'status', 403),
        ),
      );
    },
  );

  test('404 is a missing destination without creating a request', () async {
    final client = _seerr((request) async {
      expect(request.method, 'GET');
      return http.Response('{}', 404);
    });
    addTearDown(client.dispose);
    final container = _container(seerr: client);
    expect(await container.read(mediaDestinationProvider(uri).future), isNull);
  });

  for (final wrongIdentity in [false, true]) {
    test(
      'explicit Jellyfin item verifies returned identity ($wrongIdentity)',
      () async {
        final client = JellyfinClient(
          config: const JellyfinConfig(
            baseUrl: 'https://library.test',
            userId: 'viewer',
            accessToken: 'fixture',
            deviceId: 'test',
          ),
          httpClient: MockClient((request) async {
            expect(request.method, 'GET');
            expect(request.url.path, '/Users/viewer/Items/item42');
            return http.Response(
              jsonEncode({
                'Id': 'item42',
                'Name': 'Movie',
                'Type': 'Movie',
                'LocationType': 'FileSystem',
                'PlayAccess': 'Full',
                'ProviderIds': {'Tmdb': wrongIdentity ? '99' : '42'},
              }),
              200,
            );
          }),
        );
        addTearDown(client.dispose);
        final container = _container(jellyfin: client);
        final title = await container.read(
          mediaDestinationProvider(Uri.parse('$uri&jellyfin=item42')).future,
        );
        expect(title?.title, wrongIdentity ? isNull : 'Movie');
      },
    );
  }

  test(
    'invalid or ambiguous route never initializes service clients',
    () async {
      var clients = 0;
      final container = ProviderContainer(
        overrides: [
          jellyfinClientProvider.overrideWith((_) {
            clients++;
            return null;
          }),
          jellyseerrClientProvider.overrideWith((_) {
            clients++;
            return null;
          }),
        ],
      );
      addTearDown(container.dispose);
      for (final query in [
        'kind=movie&tmdb=42&tmdb=43',
        'kind=tv&tmdb=42&series=../invalid',
        'kind=movie&tmdb=-1',
      ]) {
        expect(
          await container.read(
            mediaDestinationProvider(Uri.parse('/media/title?$query')).future,
          ),
          isNull,
        );
      }
      expect(clients, 0);
    },
  );
}
