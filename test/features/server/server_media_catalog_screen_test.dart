import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/media_catalog/data/server_media_catalog_controller.dart';
import 'package:larenor/features/server/media_catalog/domain/server_media_catalog_models.dart';
import 'package:larenor/features/server/media_catalog/presentation/server_media_catalog_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'server_admin_test_support.dart';

const _requestId = '11111111111111111111111111111111';
const _installationId = '22222222222222222222222222222222';

Map<String, Object?> _installation({int revision = 7}) => {
  'id': _installationId,
  'requestId': '33333333333333333333333333333333',
  'preparationId': '44444444444444444444444444444444',
  'inspectionId': '55555555555555555555555555555555',
  'serviceId': 'jellyfin',
  'operationId': '66666666666666666666666666666666',
  'revision': revision,
  'state': 'container_started',
  'phase': 'complete',
  'cancelRequested': false,
  'installAvailable': false,
  'steps': const [
    {'stepId': '77777777777777777777777777777777', 'kind': 'create_container'},
    {'stepId': '88888888888888888888888888888888', 'kind': 'start_container'},
  ],
  'errorCode': null,
  'createdAt': '2026-09-23T09:00:00.000Z',
  'updatedAt': '2026-09-23T09:01:00.000Z',
};

Map<String, Object?> _installationWith(Map<String, Object?> changes) => {
  ..._installation(),
  ...changes,
  'id': changes['id'] ?? 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
};

Map<String, Object?> _catalog(
  int offset, {
  int installationRevision = 7,
  int snapshotRevision = 9,
  ServerMediaCatalogKind? mediaKind,
}) => {
  'schemaVersion': 1,
  'installationId': _installationId,
  'installationRevision': installationRevision,
  'snapshotRevision': snapshotRevision,
  'jellyfinServiceRevision': 11,
  'offset': offset,
  'nextOffset': offset == 0 ? 1 : null,
  'total': 2,
  'items': [
    {
      'itemId': offset == 0
          ? '99999999999999999999999999999999'
          : 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'mediaKey': mediaKind == ServerMediaCatalogKind.episode
          ? 'episode:tvdb:121361:1:${offset + 1}'
          : offset == 0
          ? 'movie:tmdb:603'
          : 'movie:tmdb:604',
      'title': mediaKind == ServerMediaCatalogKind.episode
          ? offset == 0
                ? 'Pilot'
                : 'Second Episode'
          : offset == 0
          ? 'The Matrix'
          : 'The Matrix Reloaded',
      'mediaKind': mediaKind == ServerMediaCatalogKind.episode
          ? 'episode'
          : 'movie',
      'runtimeSeconds': mediaKind == ServerMediaCatalogKind.episode
          ? 2700
          : 8160,
    },
  ],
};

List<Map<String, Object>> _flowSources() => [
  for (final provider in const [
    'seerr',
    'qbittorrent',
    'sonarr',
    'radarr',
    'jellyfin',
  ])
    {
      'provider': provider,
      'serviceRevision': 7,
      'snapshotRevision': 9,
      'observedAt': 1790132400,
    },
];

Map<String, Object?> _flow(String mediaKey) => {
  'mediaKey': mediaKey,
  'flowRevision': 9,
  'state': 'playable',
  'stages': [
    {
      'name': 'request',
      'state': 'complete',
      'provider': 'seerr',
      'sourceRevision': 7,
    },
    {
      'name': 'download',
      'state': 'complete',
      'provider': 'qbittorrent',
      'sourceRevision': 7,
    },
    {
      'name': 'import',
      'state': 'complete',
      'provider': mediaKey.startsWith('movie:') ? 'radarr' : 'sonarr',
      'sourceRevision': 7,
    },
    {
      'name': 'playable',
      'state': 'complete',
      'provider': 'jellyfin',
      'sourceRevision': 7,
    },
  ],
  'sources': _flowSources(),
  'seasons': const [],
  'delivery': const {
    'state': 'hardlink_verified',
    'retryAttempt': 1,
    'fileCount': 1,
  },
};

final class _CatalogFixture extends AdminFixture {
  _CatalogFixture({super.role}) {
    respond = (request) async {
      if (request.url.path.endsWith('/media/flows/authority')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return this.json({
          'requestId': _requestId,
          'mediaKey': body['mediaKey'],
          'flowRevision': 9,
          'sources': _flowSources(),
        });
      }
      if (request.url.path.endsWith('/media/flows/read')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final response = this.json({
          'requestId': _requestId,
          'flow': _flow(body['mediaKey'] as String),
        });
        return flowGate?.future ?? response;
      }
      if (request.url.path.endsWith('/admin/media/installations')) {
        if (targetGate case final gate?) await gate.future;
        return this.json({
          'installations':
              targetResponse ?? [_installation(revision: targetRevision)],
          'nextBefore': null,
        });
      }
      if (request.url.path.endsWith('/archive-health/authority')) {
        return this.json({
          'requestId': _requestId,
          'installationId': _installationId,
          'installationRevision': targetRevision,
          'snapshotRevision': snapshotRevision,
        });
      }
      if (request.url.path.endsWith('/catalog/search')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final response = this.json({
          'requestId': _requestId,
          'catalog': _catalog(
            body['offset'] as int,
            installationRevision: targetRevision,
            snapshotRevision: snapshotRevision,
            mediaKind: switch (body['mediaKind']) {
              'movie' => ServerMediaCatalogKind.movie,
              'episode' => ServerMediaCatalogKind.episode,
              _ => null,
            },
          ),
        });
        final call = catalogCalls++;
        if (call == 0) {
          final gate = firstCatalogGate;
          if (gate != null) {
            firstCatalogResponse = response;
            return gate.future;
          }
        }
        return response;
      }
      return defaultResponse(request);
    };
  }

  Completer<void>? targetGate;
  List<Object?>? targetResponse;
  int targetRevision = 7;
  int snapshotRevision = 9;
  int catalogCalls = 0;
  Completer<http.Response>? firstCatalogGate;
  http.Response? firstCatalogResponse;
  Completer<http.Response>? flowGate;
}

void main() {
  test(
    'discovers one exact ready Core target before every bounded page',
    () async {
      final fixture = _CatalogFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final controller = ServerMediaCatalogController(
        fixture.account,
        requestId: () => _requestId,
      );
      addTearDown(controller.dispose);

      await controller.searchCurrent(query: 'matrix', current: () => true);
      expect(controller.page?.items.single.title, 'The Matrix');
      await controller.searchCurrent(
        query: 'matrix',
        offset: controller.page!.nextOffset!,
        current: () => true,
      );

      expect(controller.page?.items.single.title, 'The Matrix Reloaded');
      expect(
        fixture.calls.map((request) => request.url.path),
        containsAllInOrder([
          '/prefix/api/v1/admin/media/installations',
          '/prefix/api/v1/admin/media/archive-health/authority',
          '/prefix/api/v1/admin/media/archive-health/catalog/search',
          '/prefix/api/v1/admin/media/installations',
          '/prefix/api/v1/admin/media/archive-health/authority',
          '/prefix/api/v1/admin/media/archive-health/catalog/search',
        ]),
      );
      expect(
        fixture.calls.every((request) => !request.url.query.contains('matrix')),
        isTrue,
      );
    },
  );

  test('ambiguous target and delayed logout publish no catalog', () async {
    final ambiguous = _CatalogFixture()
      ..targetResponse = [_installation(), _installation()];
    await ambiguous.account.initialize();
    addTearDown(ambiguous.account.dispose);
    final rejected = ServerMediaCatalogController(
      ambiguous.account,
      requestId: () => _requestId,
    );
    addTearDown(rejected.dispose);
    await rejected.searchCurrent(query: 'matrix', current: () => true);
    expect(rejected.page, isNull);
    expect(rejected.failure, 'invalid_response');
    expect(
      ambiguous.calls.where((call) => call.url.path.endsWith('/authority')),
      isEmpty,
    );

    final delayed = _CatalogFixture()..targetGate = Completer<void>();
    await delayed.account.initialize();
    addTearDown(delayed.account.dispose);
    final retired = ServerMediaCatalogController(
      delayed.account,
      requestId: () => _requestId,
    );
    addTearDown(retired.dispose);
    final search = retired.searchCurrent(query: 'matrix', current: () => true);
    await Future<void>.delayed(Duration.zero);
    await delayed.account.signOut();
    delayed.targetGate!.complete();
    await search;
    expect(retired.page, isNull);
    expect(retired.failure, isNull);
  });

  test(
    'one ready target plus any incoherent sibling fails before authority',
    () async {
      final malformed = <Map<String, Object?>>[
        _installationWith({
          'state': 'queued',
          'phase': 'executing',
          'revision': 1,
        }),
        _installationWith({
          'state': 'queued',
          'phase': 'queued',
          'revision': 2,
        }),
        _installationWith({
          'state': 'queued',
          'phase': 'queued',
          'revision': 1,
          'cancelRequested': true,
        }),
        _installationWith({
          'state': 'running',
          'phase': 'queued',
          'revision': 2,
        }),
        _installationWith({
          'state': 'running',
          'phase': 'executing',
          'revision': 1,
        }),
        _installationWith({'state': 'container_started', 'phase': 'executing'}),
        _installationWith({
          'state': 'container_started',
          'phase': 'complete',
          'revision': 1,
        }),
        _installationWith({
          'state': 'container_started',
          'errorCode': 'worker_unavailable',
        }),
        _installationWith({'state': 'cancelled', 'cancelRequested': false}),
        _installationWith({'state': 'needs_attention', 'errorCode': null}),
        _installationWith({'state': 'failed', 'errorCode': null}),
      ];

      for (final sibling in malformed) {
        final fixture = _CatalogFixture()
          ..targetResponse = [_installation(), sibling];
        await fixture.account.initialize();
        final controller = ServerMediaCatalogController(
          fixture.account,
          requestId: () => _requestId,
        );

        await controller.searchCurrent(query: 'matrix', current: () => true);

        expect(controller.page, isNull, reason: '$sibling');
        expect(controller.failure, 'invalid_response', reason: '$sibling');
        expect(
          fixture.calls.where(
            (call) =>
                call.url.path.endsWith('/authority') ||
                call.url.path.endsWith('/catalog/search'),
          ),
          isEmpty,
          reason: '$sibling',
        );
        controller.dispose();
        fixture.account.dispose();
      }
    },
  );

  test(
    'next page rejects a replacement installation before authority',
    () async {
      final fixture = _CatalogFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final controller = ServerMediaCatalogController(
        fixture.account,
        requestId: () => _requestId,
      );
      addTearDown(controller.dispose);
      await controller.searchCurrent(query: 'matrix', current: () => true);
      final next = controller.page!.nextOffset!;
      fixture.targetRevision = 8;
      final authorityBefore = fixture.calls
          .where((call) => call.url.path.endsWith('/authority'))
          .length;

      await controller.searchCurrent(
        query: 'matrix',
        offset: next,
        current: () => true,
      );

      expect(controller.page, isNull);
      expect(controller.failure, 'invalid_response');
      expect(
        fixture.calls
            .where((call) => call.url.path.endsWith('/authority'))
            .length,
        authorityBefore,
      );
    },
  );

  test('member policy issues no installation or catalog request', () async {
    final fixture = _CatalogFixture(role: ServerRole.member);
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final controller = ServerMediaCatalogController(
      fixture.account,
      requestId: () => _requestId,
    );
    addTearDown(controller.dispose);

    await controller.searchCurrent(query: 'matrix', current: () => true);

    expect(controller.page, isNull);
    expect(controller.failure, isNull);
    expect(fixture.adminCalls, isEmpty);
  });

  testWidgets('filter change retires a delayed previous catalog result', (
    tester,
  ) async {
    final fixture = _CatalogFixture()
      ..firstCatalogGate = Completer<http.Response>();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: const CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerMediaCatalogScreen(requestId: _fixedRequestId),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('server-media-catalog-search-field')),
      'matrix',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();
    expect(fixture.catalogCalls, 1);

    await tester.tap(
      find.byKey(const ValueKey('server-media-catalog-filter-tv')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pilot'), findsOneWidget);
    expect(find.text('The Matrix'), findsNothing);
    final searchBodies = fixture.calls
        .where((call) => call.url.path.endsWith('/catalog/search'))
        .map((call) => jsonDecode(call.body) as Map<String, dynamic>)
        .toList();
    expect(searchBodies, hasLength(2));
    expect(searchBodies.last['mediaKind'], 'episode');
    expect(searchBodies.last['offset'], 0);

    fixture.firstCatalogGate!.complete(fixture.firstCatalogResponse!);
    await tester.pumpAndSettle();
    expect(find.text('Pilot'), findsOneWidget);
    expect(find.text('The Matrix'), findsNothing);
  });

  testWidgets(
    'catalog result opens one read-only central flow with ordered source evidence',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final fixture = _CatalogFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverAccountControllerProvider.overrideWithValue(fixture.account),
          ],
          child: const CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ServerMediaCatalogScreen(requestId: _fixedRequestId),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('server-media-catalog-search-field')),
        'matrix',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      final item = find.byKey(
        const ValueKey(
          'server-media-catalog-item-99999999999999999999999999999999',
        ),
      );
      expect(tester.getSemantics(item).flagsCollection.isButton, isTrue);
      expect(tester.getRect(item).height, greaterThanOrEqualTo(48));
      await tester.tap(item);
      await tester.pumpAndSettle();

      expect(
        fixture.calls.where(
          (call) => call.url.path.endsWith('/media/flows/authority'),
        ),
        hasLength(1),
      );
      expect(
        fixture.calls.where(
          (call) => call.url.path.endsWith('/media/flows/read'),
        ),
        hasLength(1),
      );
      expect(
        find.byKey(const ValueKey('server-media-flow-stage-request')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('server-media-flow-stage-download')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('server-media-flow-stage-import')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('server-media-flow-stage-playable')),
        findsOneWidget,
      );
      expect(find.text('seerr'), findsOneWidget);
      expect(find.text('qbittorrent'), findsOneWidget);
      expect(find.text('radarr'), findsOneWidget);
      expect(find.text('jellyfin'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('server-media-flow-refresh')),
        findsOneWidget,
      );
      semantics.dispose();
    },
  );

  testWidgets('episode result uses its canonical series flow authority', (
    tester,
  ) async {
    final fixture = _CatalogFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: const CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerMediaCatalogScreen(requestId: _fixedRequestId),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('server-media-catalog-filter-tv')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('server-media-catalog-search-field')),
      'pilot',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey(
          'server-media-catalog-item-99999999999999999999999999999999',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final authority = fixture.calls.singleWhere(
      (call) => call.url.path.endsWith('/media/flows/authority'),
    );
    expect(jsonDecode(authority.body), {
      'requestId': _requestId,
      'mediaKey': 'series:tvdb:121361',
    });
    expect(find.text('sonarr'), findsOneWidget);
  });

  testWidgets('popping a delayed flow read publishes no retired route state', (
    tester,
  ) async {
    final fixture = _CatalogFixture()..flowGate = Completer<http.Response>();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: const CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerMediaCatalogScreen(requestId: _fixedRequestId),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('server-media-catalog-search-field')),
      'matrix',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey(
          'server-media-catalog-item-99999999999999999999999999999999',
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      fixture.calls.where(
        (call) => call.url.path.endsWith('/media/flows/read'),
      ),
      hasLength(1),
    );

    Navigator.of(
      tester.element(find.byKey(const ValueKey('server-media-flow-loading'))),
    ).pop();
    await tester.pumpAndSettle();
    fixture.flowGate!.complete(
      fixture.json({'requestId': _requestId, 'flow': _flow('movie:tmdb:603')}),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('server-media-flow-stage-request')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('$locale Core catalog fits $width tablet/DeX at 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final fixture = _CatalogFixture();
        await fixture.account.initialize();
        addTearDown(() {
          fixture.account.dispose();
          tester.view.reset();
        });
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              serverAccountControllerProvider.overrideWithValue(
                fixture.account,
              ),
            ],
            child: CupertinoApp(
              locale: Locale(locale),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const ServerMediaCatalogScreen(requestId: _fixedRequestId),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(fixture.calls, hasLength(2), reason: 'only account bootstrap');

        final filters = find.byKey(
          const ValueKey('server-media-catalog-filters'),
        );
        expect(tester.getRect(filters).height, greaterThanOrEqualTo(48));
        expect(
          find.byKey(const ValueKey('server-media-catalog-filter-all')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('server-media-catalog-filter-movies')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('server-media-catalog-filter-tv')),
          findsOneWidget,
        );

        final field = find.byKey(
          const ValueKey('server-media-catalog-search-field'),
        );
        await tester.enterText(field, 'matrix');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(find.text('The Matrix'), findsOneWidget);
        expect(fixture.mutations, hasLength(2));
        await tester.tap(
          find.byKey(const ValueKey('server-media-catalog-filter-tv')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Pilot'), findsOneWidget);
        final filteredBodies = fixture.calls
            .where((call) => call.url.path.endsWith('/catalog/search'))
            .map((call) => jsonDecode(call.body) as Map<String, dynamic>)
            .toList();
        expect(filteredBodies.last['mediaKind'], 'episode');
        expect(filteredBodies.last['offset'], 0);
        final next = find.byKey(const ValueKey('server-media-catalog-next'));
        await tester.scrollUntilVisible(
          next,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.getRect(next).height, greaterThanOrEqualTo(48));
        expect(tester.getSemantics(next).flagsCollection.isButton, isTrue);
        await tester.tap(next);
        await tester.pumpAndSettle();
        expect(find.text('Second Episode'), findsOneWidget);
        final pagedBody = jsonDecode(
          fixture.calls
              .lastWhere((call) => call.url.path.endsWith('/catalog/search'))
              .body,
        ) as Map<String, dynamic>;
        expect(pagedBody['mediaKind'], 'episode');
        expect(pagedBody['offset'], 1);
        final item = find.byKey(
          const ValueKey(
            'server-media-catalog-item-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          ),
        );
        await tester.scrollUntilVisible(
          item,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(item);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('server-media-flow-stage-request')),
          findsOneWidget,
        );
        final refresh = find.byKey(const ValueKey('server-media-flow-refresh'));
        await tester.scrollUntilVisible(
          refresh,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.getRect(refresh).height, greaterThanOrEqualTo(48));
        expect(tester.getSemantics(refresh).flagsCollection.isButton, isTrue);
        semantics.dispose();
        expect(tester.takeException(), isNull);
      });
    }
  }
}

String _fixedRequestId() => _requestId;
