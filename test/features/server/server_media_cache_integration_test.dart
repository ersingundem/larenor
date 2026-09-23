import 'dart:async';
import 'dart:convert' as convert;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/media_catalog/data/server_media_catalog_cache.dart';
import 'package:larenor/features/server/media_catalog/data/server_media_catalog_controller.dart';
import 'package:larenor/features/server/media_catalog/domain/server_media_catalog_models.dart';
import 'package:larenor/features/server/media_catalog/presentation/server_media_catalog_screen.dart';
import 'package:larenor/features/server/media_flow/data/server_media_flow_cache.dart';
import 'package:larenor/features/server/media_flow/data/server_media_flow_controller.dart';
import 'package:larenor/features/server/media_flow/domain/server_media_flow_models.dart';
import 'package:larenor/features/server/media_result_origin.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'server_admin_test_support.dart';

const _requestId = '11111111111111111111111111111111';
const _installationId = '22222222222222222222222222222222';
const _mediaKey = 'movie:tmdb:603';
final _now = DateTime.utc(2026, 9, 23, 8);

final class _CatalogBackend implements ServerMediaCatalogCacheBackend {
  String? value;
  Completer<void>? writeGate;

  @override
  Future<String?> read() async => value;

  @override
  Future<bool> compareAndClear(String expected) async {
    if (value != expected) return false;
    value = null;
    return true;
  }

  @override
  Future<bool> compareAndWrite(
    String? expected,
    String next, {
    required bool Function() current,
  }) async {
    if (!current() || value != expected) return false;
    value = next;
    final gate = writeGate;
    if (gate != null) await gate.future;
    if (!current()) {
      await compareAndClear(next);
      return false;
    }
    return true;
  }
}

final class _FlowBackend implements ServerMediaFlowCacheBackend {
  String? value;
  Completer<void>? writeGate;

  @override
  Future<String?> read() async => value;

  @override
  Future<bool> compareAndClear(String expected) async {
    if (value != expected) return false;
    value = null;
    return true;
  }

  @override
  Future<bool> compareAndWrite(
    String? expected,
    String next, {
    required bool Function() current,
  }) async {
    if (!current() || value != expected) return false;
    value = next;
    final gate = writeGate;
    if (gate != null) await gate.future;
    if (!current()) {
      await compareAndClear(next);
      return false;
    }
    return true;
  }

  @override
  Future<void> clear() async => value = null;

  @override
  Future<void> write(String value) async => this.value = value;
}

List<Map<String, Object>> _sources() => [
  for (final provider in serverMediaFlowProviderOrder)
    {
      'provider': provider,
      'serviceRevision': 7,
      'snapshotRevision': 9,
      'observedAt': _now.millisecondsSinceEpoch ~/ 1000 - 60,
    },
];

Map<String, Object?> _pageJson({int itemCount = 1}) => {
  'schemaVersion': 1,
  'installationId': _installationId,
  'installationRevision': 7,
  'snapshotRevision': 9,
  'jellyfinServiceRevision': 11,
  'offset': 0,
  'nextOffset': null,
  'total': itemCount,
  'items': [
    for (var index = 1; index <= itemCount; index++)
      {
        'itemId': index.toRadixString(16).padLeft(32, '0'),
        'mediaKey': 'movie:tmdb:${602 + index}',
        'title': index == 1 ? 'The Matrix' : 'The Matrix Reloaded',
        'mediaKind': 'movie',
        'runtimeSeconds': 8160,
      },
  ],
};

ServerMediaCatalogPage _page() => ServerMediaCatalogPage.fromJson(
  _pageJson(),
  query: 'matrix',
  mediaKind: null,
);

Map<String, Object?> _flowJson() => {
  'mediaKey': _mediaKey,
  'flowRevision': 9,
  'state': 'playable',
  'stages': const [
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
      'provider': 'radarr',
      'sourceRevision': 7,
    },
    {
      'name': 'playable',
      'state': 'complete',
      'provider': 'jellyfin',
      'sourceRevision': 7,
    },
  ],
  'sources': _sources(),
  'seasons': const [],
  'delivery': const {
    'state': 'hardlink_verified',
    'retryAttempt': 1,
    'fileCount': 1,
  },
};

ServerMediaFlowStatus _flow() => ServerMediaFlowStatus.fromJson(_flowJson());

final class _MediaFixture extends AdminFixture {
  _MediaFixture() {
    respond = (request) async {
      if (request.url.path.endsWith('/media/catalog/target')) {
        targetCalls++;
        return json({
          'schemaVersion': 1,
          'installationId': _installationId,
          'installationRevision': 7,
          'snapshotRevision': 9,
          'jellyfinServiceRevision': 11,
        });
      }
      if (request.url.path.endsWith('/media/catalog/search')) {
        catalogCalls++;
        if (catalogFailure) {
          return json({
            'error': {'code': 'server_error'},
          }, 503);
        }
        final body = convert.jsonDecode(request.body) as Map<String, dynamic>;
        final response = json({
          'requestId': _requestId,
          'catalog': _pageJson(
            itemCount: catalogItemsFollowLimit ? body['limit'] as int : 1,
          ),
        });
        return catalogGate?.future ?? response;
      }
      if (request.url.path.endsWith('/media/flows/authority')) {
        authorityCalls++;
        return json({
          'requestId': _requestId,
          'mediaKey': _mediaKey,
          'flowRevision': 9,
          'sources': _sources(),
        });
      }
      if (request.url.path.endsWith('/media/flows/read')) {
        flowCalls++;
        return json({'requestId': _requestId, 'flow': _flowJson()});
      }
      return defaultResponse(request);
    };
  }

  int targetCalls = 0, catalogCalls = 0, authorityCalls = 0, flowCalls = 0;
  bool catalogFailure = false;
  bool catalogItemsFollowLimit = false;
  Completer<http.Response>? catalogGate;
}

void main() {
  test(
    'catalog and flow screens consume only freshly authorized cache hits',
    () async {
      final fixture = _MediaFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final catalogCache = ServerMediaCatalogCache(
        backend: _CatalogBackend(),
        now: () => _now,
      );
      final flowCache = ServerMediaFlowCache(
        backend: _FlowBackend(),
        now: () => _now,
      );

      final firstCatalog = ServerMediaCatalogController(
        fixture.account,
        cache: catalogCache,
        requestId: () => _requestId,
      );
      await firstCatalog.searchCurrent(query: 'matrix', current: () => true);
      expect(firstCatalog.origin, ServerMediaResultOrigin.live);
      expect(fixture.catalogCalls, 1);
      firstCatalog.dispose();

      final cachedCatalog = ServerMediaCatalogController(
        fixture.account,
        cache: catalogCache,
        requestId: () => _requestId,
      );
      addTearDown(cachedCatalog.dispose);
      await cachedCatalog.searchCurrent(query: 'matrix', current: () => true);
      expect(cachedCatalog.page?.items.single.title, 'The Matrix');
      expect(cachedCatalog.origin, ServerMediaResultOrigin.verifiedCache);
      expect(fixture.targetCalls, 2);
      expect(fixture.catalogCalls, 1);

      final firstFlow = ServerMediaFlowController(
        fixture.account,
        cache: flowCache,
        requestId: () => _requestId,
      );
      await firstFlow.load(_mediaKey, current: () => true);
      expect(firstFlow.origin, ServerMediaResultOrigin.live);
      expect(fixture.flowCalls, 1);
      firstFlow.dispose();

      final cachedFlow = ServerMediaFlowController(
        fixture.account,
        cache: flowCache,
        requestId: () => _requestId,
      );
      addTearDown(cachedFlow.dispose);
      await cachedFlow.load(_mediaKey, current: () => true);
      expect(cachedFlow.status?.state, 'playable');
      expect(cachedFlow.origin, ServerMediaResultOrigin.verifiedCache);
      expect(fixture.authorityCalls, 2);
      expect(fixture.flowCalls, 1);
    },
  );

  test('catalog cache binds the requested result limit', () async {
    final fixture = _MediaFixture()..catalogItemsFollowLimit = true;
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final cache = ServerMediaCatalogCache(
      backend: _CatalogBackend(),
      now: () => _now,
    );
    final wide = ServerMediaCatalogController(
      fixture.account,
      cache: cache,
      requestId: () => _requestId,
    );
    await wide.searchCurrent(
      query: 'matrix',
      limit: 2,
      current: () => true,
    );
    expect(wide.page?.items, hasLength(2));
    wide.dispose();

    final narrow = ServerMediaCatalogController(
      fixture.account,
      cache: cache,
      requestId: () => _requestId,
    );
    addTearDown(narrow.dispose);
    await narrow.searchCurrent(
      query: 'matrix',
      limit: 1,
      current: () => true,
    );

    expect(narrow.page?.items, hasLength(1));
    expect(narrow.origin, ServerMediaResultOrigin.live);
    expect(fixture.catalogCalls, 2);
  });

  test(
    'retirement during cache persistence clears only the stale write',
    () async {
      final fixture = _MediaFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final catalogBackend = _CatalogBackend()..writeGate = Completer<void>();
      final controller = ServerMediaCatalogController(
        fixture.account,
        cache: ServerMediaCatalogCache(
          backend: catalogBackend,
          now: () => _now,
        ),
        requestId: () => _requestId,
      );
      addTearDown(controller.dispose);
      var current = true;

      final pending = controller.searchCurrent(
        query: 'matrix',
        current: () => current,
      );
      while (catalogBackend.value == null) {
        await Future<void>.delayed(Duration.zero);
      }
      current = false;
      catalogBackend.writeGate!.complete();
      await pending;

      expect(controller.page, isNull);
      expect(controller.origin, isNull);
      expect(catalogBackend.value, isNull);
    },
  );

  test(
    'flow route retirement during persistence clears its stale write',
    () async {
      final fixture = _MediaFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final flowBackend = _FlowBackend()..writeGate = Completer<void>();
      final controller = ServerMediaFlowController(
        fixture.account,
        cache: ServerMediaFlowCache(backend: flowBackend, now: () => _now),
        requestId: () => _requestId,
      );
      addTearDown(controller.dispose);
      var current = true;

      final pending = controller.load(_mediaKey, current: () => current);
      while (flowBackend.value == null) {
        await Future<void>.delayed(Duration.zero);
      }
      current = false;
      flowBackend.writeGate!.complete();
      await pending;

      expect(controller.status, isNull);
      expect(controller.origin, isNull);
      expect(flowBackend.value, isNull);
    },
  );

  testWidgets('app pause retires a catalog cache write after persistence', (
    tester,
  ) async {
    final fixture = _MediaFixture();
    await fixture.account.initialize();
    final backend = _CatalogBackend()..writeGate = Completer<void>();
    addTearDown(() {
      fixture.account.dispose();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerMediaCatalogScreen(
            requestId: _fixedRequestId,
            catalogCache: ServerMediaCatalogCache(
              backend: backend,
              now: () => _now,
            ),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('server-media-catalog-search-field')),
      'matrix',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    while (backend.value == null) {
      await tester.pump();
    }
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    backend.writeGate!.complete();
    await tester.pumpAndSettle();

    expect(find.text('The Matrix'), findsNothing);
    expect(backend.value, isNull);
  });

  testWidgets('cache miss and Core failure expose an accessible fallback', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final fixture = _MediaFixture()..catalogFailure = true;
    await fixture.account.initialize();
    addTearDown(() {
      fixture.account.dispose();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerMediaCatalogScreen(
            requestId: _fixedRequestId,
            catalogCache: ServerMediaCatalogCache(
              backend: _CatalogBackend(),
              now: () => _now,
            ),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('server-media-catalog-search-field')),
      'matrix',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    final fallback = find.byKey(
      const ValueKey('server-media-catalog-cache-fallback'),
    );
    expect(fallback, findsOneWidget);
    expect(tester.getSemantics(fallback).flagsCollection.isLiveRegion, isTrue);
    expect(find.text('The Matrix'), findsNothing);
    expect(fixture.catalogCalls, 1);
    semantics.dispose();
  });

  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$locale cache hit is accessible at $width and matches live rendering',
        (tester) async {
          final semantics = tester.ensureSemantics();
          final fixture = _MediaFixture();
          await fixture.account.initialize();
          final catalogBackend = _CatalogBackend();
          final flowBackend = _FlowBackend();
          final catalogCache = ServerMediaCatalogCache(
            backend: catalogBackend,
            now: () => _now,
          );
          final flowCache = ServerMediaFlowCache(
            backend: flowBackend,
            now: () => _now,
          );
          final scope = ServerMediaCatalogCacheScope.fromSession(
            fixture.account.session!,
          );
          await catalogCache.write(scope, _page(), current: () => true);
          await flowCache.write(
            ServerMediaFlowCacheScope.fromSession(fixture.account.session!),
            _flow(),
            current: () => true,
          );
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
                home: ServerMediaCatalogScreen(
                  requestId: _fixedRequestId,
                  catalogCache: catalogCache,
                  flowCache: flowCache,
                ),
              ),
            ),
          );
          await tester.enterText(
            find.byKey(const ValueKey('server-media-catalog-search-field')),
            'matrix',
          );
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await tester.pumpAndSettle();

          final catalogOrigin = find.byKey(
            const ValueKey('server-media-catalog-cache-origin'),
          );
          expect(catalogOrigin, findsOneWidget);
          expect(
            tester.getSemantics(catalogOrigin).flagsCollection.isLiveRegion,
            isTrue,
          );
          expect(find.text('The Matrix'), findsOneWidget);
          expect(fixture.catalogCalls, 0);

          await tester.tap(
            find.byKey(
              const ValueKey(
                'server-media-catalog-item-33333333333333333333333333333333',
              ),
            ),
          );
          await tester.pumpAndSettle();
          final flowOrigin = find.byKey(
            const ValueKey('server-media-flow-cache-origin'),
          );
          expect(flowOrigin, findsOneWidget);
          expect(
            tester.getSemantics(flowOrigin).flagsCollection.isLiveRegion,
            isTrue,
          );
          expect(
            find.byKey(const ValueKey('server-media-flow-stage-playable')),
            findsOneWidget,
          );
          expect(fixture.flowCalls, 0);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }
}

String _fixedRequestId() => _requestId;
