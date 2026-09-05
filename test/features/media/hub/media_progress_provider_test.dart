import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/media/arr/data/arr_client.dart';
import 'package:larenor/features/media/arr/data/arr_config.dart';
import 'package:larenor/features/media/arr/providers/radarr_providers.dart';
import 'package:larenor/features/media/arr/providers/sonarr_providers.dart';
import 'package:larenor/features/media/hub/domain/media_identity.dart';
import 'package:larenor/features/media/hub/domain/media_read_result.dart';
import 'package:larenor/features/media/hub/domain/media_title.dart';
import 'package:larenor/features/media/hub/providers/media_catalog_providers.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_client.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_config.dart';
import 'package:larenor/features/media/jellyseerr/data/models/jellyseerr_request_item.dart';
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';

const identity = MediaIdentity(kind: MediaKind.movie, tmdbId: 42);
http.Response library([String title = 'Film']) => http.Response(
  jsonEncode([
    {
      'id': 5,
      'title': title,
      'tmdbId': 42,
      'monitored': true,
      'hasFile': false,
    },
  ]),
  200,
);
ArrClient arr(Future<http.Response> Function(http.Request) handler) =>
    ArrClient(
      config: const ArrConfig(
        baseUrl: 'https://fixture.test',
        apiKey: 'fixture',
      ),
      resourcePath: 'movie',
      idFieldName: 'tmdbId',
      httpClient: MockClient(handler),
    );

void main() {
  for (final testCase in [
    (status: 401, failure: HealthFailure.authentication),
    (status: 403, failure: HealthFailure.permission),
    (status: 500, failure: HealthFailure.server),
    (status: 0, failure: HealthFailure.timeout),
  ]) {
    test(
      'queue ${testCase.status} remains source failure with one read, not fake zero',
      () async {
        var queueReads = 0;
        final client = arr((request) async {
          expect(request.method, 'GET');
          if (request.url.path.endsWith('/movie')) return library();
          queueReads++;
          if (testCase.status == 0) throw TimeoutException('fixture');
          return http.Response('private upstream text', testCase.status);
        });
        addTearDown(client.dispose);
        final container = ProviderContainer(
          overrides: [
            jellyfinClientProvider.overrideWith((_) => null),
            jellyseerrClientProvider.overrideWith((_) => null),
            sonarrClientProvider.overrideWith((_) => null),
            radarrClientProvider.overrideWith((_) => client),
          ],
        );
        addTearDown(container.dispose);
        container.listen(mediaLibraryIndexProvider, (_, _) {});
        final index = await container.read(mediaLibraryIndexProvider.future);
        expect(queueReads, 1);
        expect(index.readIssues, [
          MediaReadIssue(
            const MediaReadKey(IntegrationId.radarr, MediaReadOperation.queue),
            testCase.failure,
          ),
        ]);
        final title = index.titleFor(identity)!;
        expect(title.title, 'Film');
        expect(title.transfers, isEmpty);
        expect(title.downloadProgress, isNull);
        expect(title.availability, MediaAvailability.monitored);
        expect(title.isPlayable, isFalse);
      },
    );
  }

  test(
    'request failure uses original 403 and refresh recomputes current evidence',
    () async {
      var denied = true;
      var count = 0;
      final client = JellyseerrClient(
        config: const JellyseerrConfig(
          baseUrl: 'https://seerr.test',
          apiKey: 'fixture',
        ),
        httpClient: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/request');
          expect(request.url.queryParameters['take'], '50');
          count++;
          return denied
              ? http.Response('denied', 403)
              : http.Response(
                  jsonEncode({
                    'results': [
                      {
                        'id': 1,
                        'type': 'movie',
                        'status': 3,
                        'media': {'tmdbId': 42, 'title': 'Film'},
                      },
                    ],
                  }),
                  200,
                );
        }),
      );
      addTearDown(client.dispose);
      final container = ProviderContainer(
        overrides: [
          jellyfinClientProvider.overrideWith((_) => null),
          jellyseerrClientProvider.overrideWith((_) => client),
          sonarrClientProvider.overrideWith((_) => null),
          radarrClientProvider.overrideWith((_) => null),
        ],
      );
      addTearDown(container.dispose);
      container.listen(mediaLibraryIndexProvider, (_, _) {});
      final deniedIndex = await container.read(
        mediaLibraryIndexProvider.future,
      );
      expect(count, 1);
      expect(deniedIndex.readIssues.single.failure, HealthFailure.permission);
      denied = false;
      container.invalidate(mediaLibraryIndexProvider);
      final refreshed = await container.read(mediaLibraryIndexProvider.future);
      expect(count, 2);
      expect(refreshed.readIssues, isEmpty);
      expect(
        refreshed.titleFor(identity)?.requestStatus,
        JellyseerrRequestStatus.declined,
      );
      expect(
        refreshed.titleFor(identity)?.availability,
        MediaAvailability.failed,
      );
    },
  );

  test(
    'old account async library result cannot replace current account progress',
    () async {
      final oldReadStarted = Completer<void>();
      final oldRead = Completer<http.Response>();
      final oldClient = arr((request) async {
        if (request.url.path.endsWith('/movie')) {
          oldReadStarted.complete();
          return oldRead.future;
        }
        return http.Response('{"records":[]}', 200);
      });
      final nextClient = arr(
        (request) async => request.url.path.endsWith('/movie')
            ? library('Current account film')
            : http.Response(
                '{"records":[{"id":2,"movieId":5,"status":"paused"}]}',
                200,
              ),
      );
      addTearDown(oldClient.dispose);
      addTearDown(nextClient.dispose);
      var current = oldClient;
      final container = ProviderContainer(
        overrides: [
          jellyfinClientProvider.overrideWith((_) => null),
          jellyseerrClientProvider.overrideWith((_) => null),
          sonarrClientProvider.overrideWith((_) => null),
          radarrClientProvider.overrideWith((_) => current),
        ],
      );
      addTearDown(container.dispose);
      container.listen(mediaLibraryIndexProvider, (_, _) {});
      await oldReadStarted.future;
      current = nextClient;
      container.invalidate(radarrClientProvider);
      final next = await container.read(mediaLibraryIndexProvider.future);
      expect(next.titleFor(identity)?.title, 'Current account film');
      expect(next.titleFor(identity)?.availability, MediaAvailability.paused);
      oldRead.complete(library('Old private film'));
      await container.pump();
      final finalTitle = container
          .read(mediaLibraryIndexProvider)
          .requireValue
          .titleFor(identity)!;
      expect(finalTitle.title, 'Current account film');
      expect(finalTitle.transfers.single.id, '2');
      expect(finalTitle.availability, MediaAvailability.paused);
    },
  );
}
