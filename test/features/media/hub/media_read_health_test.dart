import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/media/arr/data/arr_client.dart';
import 'package:larenor/features/media/arr/data/arr_config.dart';
import 'package:larenor/features/media/arr/providers/radarr_providers.dart';
import 'package:larenor/features/media/arr/providers/sonarr_providers.dart';
import 'package:larenor/features/media/hub/domain/media_read_result.dart';
import 'package:larenor/features/media/hub/providers/media_catalog_providers.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_client.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_client.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_config.dart';
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';

ArrClient _radarr(
  Future<http.Response> Function(http.Request) handler, {
  HealthSession? session,
}) => ArrClient(
  config: const ArrConfig(baseUrl: 'https://radarr.test', apiKey: 'fixture'),
  resourcePath: 'movie',
  idFieldName: 'tmdbId',
  healthSession: session,
  httpClient: MockClient(handler),
);

ProviderContainer _container({
  ArrClient? radarr,
  JellyfinClient? jellyfin,
  JellyseerrClient? jellyseerr,
}) => ProviderContainer(
  overrides: [
    jellyfinClientProvider.overrideWith((_) => jellyfin),
    jellyseerrClientProvider.overrideWith((_) => jellyseerr),
    sonarrClientProvider.overrideWith((_) => null),
    radarrClientProvider.overrideWith((_) => radarr),
  ],
);

http.Response _calendar([String title = 'Available title']) => http.Response(
  jsonEncode([
    {'title': title, 'tmdbId': 42},
  ]),
  200,
);

void main() {
  for (final scenario in [
    (
      name: '401',
      failure: HealthFailure.authentication,
      reply: () async => http.Response('private upstream body', 401),
    ),
    (
      name: '403',
      failure: HealthFailure.permission,
      reply: () async => http.Response('private upstream body', 403),
    ),
    (
      name: 'timeout',
      failure: HealthFailure.timeout,
      reply: () async => throw TimeoutException('secret upstream URL'),
    ),
    (
      name: 'network',
      failure: HealthFailure.transport,
      reply: () async => throw http.ClientException('secret upstream URL'),
    ),
    (
      name: 'malformed 200',
      failure: HealthFailure.invalidResponse,
      reply: () async => http.Response('{}', 200),
    ),
  ]) {
    test(
      '${scenario.name} keeps usable rows and reports failed library evidence',
      () async {
        final monitor = HealthMonitor();
        addTearDown(monitor.dispose);
        final session = monitor.bind(IntegrationId.radarr, configured: true);
        expect(
          monitor.read(IntegrationId.radarr).lastSuccessfulRead,
          isNull,
          reason: 'Saved configuration is not a successful read',
        );
        final client = _radarr(
          (request) async => switch (request.url.path) {
            '/api/v3/movie' => await scenario.reply(),
            '/api/v3/calendar' => _calendar(),
            '/api/v3/queue' => http.Response('{"records":[]}', 200),
            _ => throw StateError('unexpected endpoint'),
          },
          session: session,
        );
        addTearDown(client.dispose);
        final container = _container(radarr: client);
        addTearDown(container.dispose);
        container.listen(mediaHubRowsProvider, (_, _) {});
        final rows = await container.read(mediaHubRowsProvider.future);
        expect(rows.single.titles.single.title, 'Available title');
        expect(rows.readIssues, [
          MediaReadIssue(
            const MediaReadKey(
              IntegrationId.radarr,
              MediaReadOperation.library,
            ),
            scenario.failure,
          ),
        ]);
        expect(
          rows.successfulReads,
          contains(
            const MediaReadKey(
              IntegrationId.radarr,
              MediaReadOperation.calendar,
            ),
          ),
        );
        expect(
          rows.successfulReads,
          isNot(
            contains(
              const MediaReadKey(
                IntegrationId.radarr,
                MediaReadOperation.library,
              ),
            ),
          ),
        );
        expect(monitor.read(IntegrationId.radarr).failure, scenario.failure);
        expect(
          monitor.read(IntegrationId.radarr).lastSuccessfulRead,
          isNotNull,
        );
        expect(() => rows.clear(), throwsUnsupportedError);
        expect(() => rows.readIssues.clear(), throwsUnsupportedError);
      },
    );
  }

  test(
    'using a cached index and queue does not refresh the last successful read',
    () async {
      var now = DateTime.utc(2026, 1, 1, 10);
      final monitor = HealthMonitor(now: () => now);
      addTearDown(monitor.dispose);
      final client = _radarr(
        (request) async => switch (request.url.path) {
          '/api/v3/movie' => http.Response('[]', 200),
          '/api/v3/queue' => http.Response('{"records":[]}', 200),
          '/api/v3/calendar' => http.Response('denied', 403),
          _ => throw StateError('unexpected endpoint'),
        },
        session: monitor.bind(IntegrationId.radarr, configured: true),
      );
      addTearDown(client.dispose);
      final container = _container(radarr: client);
      addTearDown(container.dispose);
      container.listen(mediaLibraryIndexProvider, (_, _) {});
      await container.read(mediaLibraryIndexProvider.future);
      final actualRead = monitor.read(IntegrationId.radarr).lastSuccessfulRead;
      expect(actualRead, now);
      now = now.add(const Duration(minutes: 10));
      container.listen(mediaHubRowsProvider, (_, _) {});
      final rows = await container.read(mediaHubRowsProvider.future);
      expect(rows.readIssues.single.failure, HealthFailure.permission);
      expect(monitor.read(IntegrationId.radarr).lastSuccessfulRead, actualRead);
    },
  );

  test('refresh rebuilds evidence and removes recovered errors', () async {
    var recovered = false;
    final client = _radarr(
      (request) async => switch (request.url.path) {
        '/api/v3/movie' => http.Response(
          recovered ? '[]' : 'denied',
          recovered ? 200 : 403,
        ),
        '/api/v3/calendar' => _calendar(),
        '/api/v3/queue' => http.Response('{"records":[]}', 200),
        _ => throw StateError('unexpected endpoint'),
      },
    );
    addTearDown(client.dispose);
    final container = _container(radarr: client);
    addTearDown(container.dispose);
    container.listen(mediaHubRowsProvider, (_, _) {});
    final previous = await container.read(mediaHubRowsProvider.future);
    expect(previous.readIssues, isNotEmpty);
    recovered = true;
    container.invalidate(radarrQueueProvider);
    container.invalidate(mediaLibraryIndexProvider);
    container.invalidate(mediaHubRowsProvider);
    final current = await container.read(mediaHubRowsProvider.future);
    expect(current.readIssues, isEmpty);
    expect(
      current.successfulReads,
      contains(
        const MediaReadKey(IntegrationId.radarr, MediaReadOperation.library),
      ),
    );
    expect(
      previous.readIssues,
      hasLength(1),
      reason: 'Earlier snapshots are immutable',
    );
  });

  for (final lateStatus in [200, 401]) {
    test(
      'late old-account $lateStatus cannot replace current data or health',
      () async {
        final oldReply = Completer<http.Response>();
        final monitor = HealthMonitor();
        addTearDown(monitor.dispose);
        final old = _radarr(
          (request) async => switch (request.url.path) {
            '/api/v3/calendar' => await oldReply.future,
            '/api/v3/queue' => http.Response('{"records":[]}', 200),
            _ => http.Response('[]', 200),
          },
          session: monitor.bind(IntegrationId.radarr, configured: true),
        );
        addTearDown(old.dispose);
        var selected = old;
        final container = ProviderContainer(
          overrides: [
            jellyfinClientProvider.overrideWith((_) => null),
            jellyseerrClientProvider.overrideWith((_) => null),
            sonarrClientProvider.overrideWith((_) => null),
            radarrClientProvider.overrideWith((ref) => selected),
          ],
        );
        addTearDown(container.dispose);
        container.listen(mediaHubRowsProvider, (_, _) {});
        await container.pump();
        await Future<void>.delayed(Duration.zero);
        final current = _radarr(
          (request) async => switch (request.url.path) {
            '/api/v3/calendar' => _calendar('New account title'),
            '/api/v3/queue' => http.Response('{"records":[]}', 200),
            _ => http.Response('[]', 200),
          },
          session: monitor.bind(IntegrationId.radarr, configured: true),
        );
        addTearDown(current.dispose);
        selected = current;
        container.invalidate(radarrClientProvider);
        final result = await container.read(mediaHubRowsProvider.future);
        expect(result.single.titles.single.title, 'New account title');
        oldReply.complete(
          lateStatus == 200
              ? _calendar('Old private title')
              : http.Response('denied', 401),
        );
        await container.pump();
        await Future<void>.delayed(Duration.zero);
        expect(
          container
              .read(mediaHubRowsProvider)
              .requireValue
              .single
              .titles
              .single
              .title,
          'New account title',
        );
        expect(
          container.read(mediaHubRowsProvider).requireValue.readIssues,
          isEmpty,
        );
        expect(monitor.read(IntegrationId.radarr).failure, isNull);
        expect(
          monitor.read(IntegrationId.radarr).lastSuccessfulRead,
          isNotNull,
        );
      },
    );
  }

  test(
    'remote search preserves Jellyfin hits when Jellyseerr denies access',
    () async {
      final jellyfin = JellyfinClient(
        config: const JellyfinConfig(
          baseUrl: 'https://jellyfin.test',
          userId: 'user',
          accessToken: 'fixture',
          deviceId: 'device',
        ),
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'Items': [
                {
                  'Id': 'movie',
                  'Name': 'Local movie',
                  'Type': 'Movie',
                  'ProviderIds': {'Tmdb': '42'},
                },
              ],
            }),
            200,
          ),
        ),
      );
      final jellyseerr = JellyseerrClient(
        config: const JellyseerrConfig(
          baseUrl: 'https://jellyseerr.test',
          apiKey: 'fixture',
        ),
        httpClient: MockClient((request) async => http.Response('denied', 403)),
      );
      addTearDown(jellyfin.dispose);
      addTearDown(jellyseerr.dispose);
      final container = _container(jellyfin: jellyfin, jellyseerr: jellyseerr);
      addTearDown(container.dispose);
      container.listen(mediaSearchProvider('movie'), (_, _) {});
      final result = await container.read(mediaSearchProvider('movie').future);
      expect(result.single.title, 'Local movie');
      expect(result.readIssues.single.read.service, IntegrationId.jellyseerr);
      expect(result.readIssues.single.failure, HealthFailure.permission);
    },
  );

  test('unconfigured services do not claim successful empty reads', () async {
    final container = _container();
    addTearDown(container.dispose);
    container.listen(mediaHubRowsProvider, (_, _) {});
    final rows = await container.read(mediaHubRowsProvider.future);
    expect(rows, isEmpty);
    expect(rows.successfulReads, isEmpty);
    expect(rows.readIssues, isEmpty);
  });

  test('a valid empty response carries success; a missing envelope carries failure', () async {
    var malformed = false;
    final jellyfin = JellyfinClient(
      config: const JellyfinConfig(
        baseUrl: 'https://jellyfin.test',
        userId: 'user',
        accessToken: 'fixture',
        deviceId: 'device',
      ),
      httpClient: MockClient(
        (request) async =>
            http.Response(malformed ? '{}' : '{"Items":[]}', 200),
      ),
    );
    addTearDown(jellyfin.dispose);
    final container = _container(jellyfin: jellyfin);
    addTearDown(container.dispose);
    container.listen(mediaLibraryIndexProvider, (_, _) {});
    final empty = await container.read(mediaLibraryIndexProvider.future);
    expect(empty.isEmpty, isTrue);
    expect(empty.readIssues, isEmpty);
    expect(
      empty.successfulReads,
      contains(
        const MediaReadKey(IntegrationId.jellyfin, MediaReadOperation.library),
      ),
    );
    malformed = true;
    container.invalidate(mediaLibraryIndexProvider);
    final failed = await container.read(mediaLibraryIndexProvider.future);
    expect(failed.isEmpty, isTrue);
    expect(failed.successfulReads, isEmpty);
    expect(failed.readIssues.single.failure, HealthFailure.invalidResponse);
  });
}
