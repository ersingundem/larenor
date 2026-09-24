import 'dart:async';
import 'dart:convert' show jsonDecode;

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/media_catalog/presentation/server_media_catalog_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_admin_test_support.dart';

const _requestId = '11111111111111111111111111111111';
const _installationId = '22222222222222222222222222222222';

Map<String, Object?> _target() => {
  'schemaVersion': 1,
  'installationId': _installationId,
  'installationRevision': 7,
  'snapshotRevision': 8,
  'jellyfinServiceRevision': 9,
};

Map<String, Object?> _catalog() => {
  'schemaVersion': 1,
  'installationId': _installationId,
  'installationRevision': 7,
  'snapshotRevision': 8,
  'jellyfinServiceRevision': 9,
  'offset': 0,
  'nextOffset': null,
  'total': 0,
  'items': const [],
};

Map<String, Object?> _rows() => {
  'requestId': _requestId,
  'installationId': _installationId,
  'installationRevision': 7,
  'bindingRevision': 4,
  'rows': {
    'schemaVersion': 1,
    'revision': 10,
    'recent': const [
      {
        'itemId': '33333333333333333333333333333333',
        'title': 'The Matrix',
        'mediaKind': 'movie',
        'addedAt': 2000000000,
        'runtimeSeconds': 8160,
        'positionSeconds': 0,
      },
    ],
    'resume': const [
      {
        'itemId': '44444444444444444444444444444444',
        'title': 'Severance — S02E01',
        'mediaKind': 'episode',
        'addedAt': 1999990000,
        'runtimeSeconds': 3600,
        'positionSeconds': 900,
      },
    ],
  },
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
    for (final stage in const [
      ('request', 'seerr'),
      ('download', 'qbittorrent'),
      ('import', 'radarr'),
      ('playable', 'jellyfin'),
    ])
      {
        'name': stage.$1,
        'state': 'complete',
        'provider': stage.$2,
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

Map<String, Object?> _resolvedRow(String itemId) {
  final episode = itemId == '44444444444444444444444444444444';
  return {
    'requestId': _requestId,
    'bindingRevision': 4,
    'catalog': {
      'schemaVersion': 1,
      'installationId': _installationId,
      'installationRevision': 7,
      'snapshotRevision': 8,
      'jellyfinServiceRevision': 9,
      'offset': 0,
      'nextOffset': null,
      'total': 1,
      'items': [
        {
          'itemId': itemId,
          'mediaKey': episode ? 'episode:tvdb:101:2:1' : 'movie:tmdb:603',
          'title': episode ? 'Severance — S02E01' : 'The Matrix',
          'mediaKind': episode ? 'episode' : 'movie',
          'runtimeSeconds': episode ? 3600 : 8160,
        },
      ],
    },
  };
}

final class _Fixture extends AdminFixture {
  _Fixture() {
    respond = (request) async {
      if (request.url.path.endsWith('/media/flows/authority')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return json({
          'requestId': _requestId,
          'mediaKey': body['mediaKey'],
          'flowRevision': 9,
          'sources': _flowSources(),
        });
      }
      if (request.url.path.endsWith('/media/flows/read')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return json({
          'requestId': _requestId,
          'flow': _flow(body['mediaKey'] as String),
        });
      }
      if (request.url.path.endsWith('/media/catalog/target')) {
        return json(_target());
      }
      if (request.url.path.endsWith('/media/rows/target')) {
        return json({
          'schemaVersion': 1,
          'installationId': _installationId,
          'installationRevision': 7,
          'bindingRevision': 4,
        });
      }
      if (request.url.path.endsWith('/media/catalog/browse')) {
        return json({'requestId': _requestId, 'catalog': _catalog()});
      }
      if (request.url.path.endsWith('/media/rows/read')) {
        rowsReads++;
        if (failRows) {
          return json({
            'error': {'code': 'media_rows_worker_unavailable'},
          }, 503);
        }
        return json(_rows());
      }
      if (request.url.path.endsWith('/media/rows/resolve')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final gate = resolveGate;
        if (gate != null) return gate.future;
        return json(_resolvedRow(body['itemId'] as String));
      }
      return defaultResponse(request);
    };
  }

  bool failRows = false;
  int rowsReads = 0;
  Completer<http.Response>? resolveGate;
}

Widget _app(_Fixture fixture, {String locale = 'en', double scale = 1}) =>
    ProviderScope(
      overrides: [
        serverAccountControllerProvider.overrideWithValue(fixture.account),
      ],
      child: CupertinoApp(
        locale: Locale(locale),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: ServerMediaCatalogScreen(
          requestId: () => _requestId,
          showAccountRows: true,
        ),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'Core media hub resolves account rows before opening central flow',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final fixture = _Fixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);

      await tester.pumpWidget(_app(fixture));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Continue watching'), findsOneWidget);
      expect(find.text('Recently added'), findsOneWidget);
      expect(find.text('Severance — S02E01'), findsOneWidget);
      expect(find.text('The Matrix'), findsOneWidget);
      expect(
        tester
            .getSemantics(
              find.byKey(
                const ValueKey(
                  'server-media-row-44444444444444444444444444444444',
                ),
              ),
            )
            .value,
        '25%',
      );
      final recentCard = find.byKey(
        const ValueKey('server-media-row-33333333333333333333333333333333'),
      );
      expect(tester.getSemantics(recentCard).flagsCollection.isButton, isTrue);
      expect(tester.getRect(recentCard).height, greaterThanOrEqualTo(48));
      expect(fixture.rowsReads, 1);
      final request = fixture.calls.singleWhere(
        (call) => call.url.path.endsWith('/media/rows/read'),
      );
      expect(jsonDecode(request.body), {
        'requestId': _requestId,
        'installationId': _installationId,
        'expectedInstallationRevision': 7,
        'expectedBindingRevision': 4,
      });
      await tester.tap(recentCard);
      await tester.pumpAndSettle();
      final resolve = fixture.calls.singleWhere(
        (call) => call.url.path.endsWith('/media/rows/resolve'),
      );
      expect(jsonDecode(resolve.body), {
        'requestId': _requestId,
        'installationId': _installationId,
        'expectedInstallationRevision': 7,
        'expectedBindingRevision': 4,
        'expectedSnapshotRevision': 8,
        'expectedJellyfinServiceRevision': 9,
        'itemId': '33333333333333333333333333333333',
      });
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
        find.byKey(const ValueKey('server-media-flow-stage-playable')),
        findsOneWidget,
      );
      semantics.dispose();
    },
  );

  testWidgets('rapid row taps resolve and navigate exactly once', (
    tester,
  ) async {
    final fixture = _Fixture()..resolveGate = Completer<http.Response>();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    await tester.pumpWidget(_app(fixture));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final targetCallsBefore = fixture.calls
        .where((call) => call.url.path.endsWith('/media/catalog/target'))
        .length;
    final card = find.byKey(
      const ValueKey('server-media-row-33333333333333333333333333333333'),
    );

    await tester.tap(card);
    await tester.tap(card);
    await tester.pump();
    expect(
      fixture.calls.where(
        (call) => call.url.path.endsWith('/media/catalog/target'),
      ),
      hasLength(targetCallsBefore + 1),
    );
    expect(
      fixture.calls.where(
        (call) => call.url.path.endsWith('/media/rows/resolve'),
      ),
      hasLength(1),
    );

    fixture.resolveGate!.complete(
      fixture.json(_resolvedRow('33333333333333333333333333333333')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('server-media-flow-stage-playable')),
      findsOneWidget,
    );
    expect(
      fixture.calls.where(
        (call) => call.url.path.endsWith('/media/rows/resolve'),
      ),
      hasLength(1),
    );
  });

  testWidgets('logout during delayed row resolution opens no stale route', (
    tester,
  ) async {
    final fixture = _Fixture()..resolveGate = Completer<http.Response>();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    await tester.pumpWidget(_app(fixture));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final card = find.byKey(
      const ValueKey('server-media-row-33333333333333333333333333333333'),
    );

    await tester.tap(card);
    await tester.pump();
    expect(
      fixture.calls.where(
        (call) => call.url.path.endsWith('/media/rows/resolve'),
      ),
      hasLength(1),
    );
    await fixture.account.signOut();
    fixture.resolveGate!.complete(
      fixture.json(_resolvedRow('33333333333333333333333333333333')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('server-media-flow-stage-playable')),
      findsNothing,
    );
    expect(
      fixture.calls.where(
        (call) => call.url.path.endsWith('/media/flows/authority'),
      ),
      isEmpty,
    );
  });

  testWidgets('rows failure offers bounded retry', (tester) async {
    final fixture = _Fixture()..failRows = true;
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    await tester.pumpWidget(_app(fixture));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('server-media-rows-error')),
      findsOneWidget,
    );
    fixture.failRows = false;
    await tester.tap(find.byKey(const ValueKey('server-media-rows-retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('The Matrix'), findsOneWidget);
    expect(fixture.rowsReads, 2);
  });

  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('$locale account rows fit $width tablet/DeX at 2x', (
        tester,
      ) async {
        final fixture = _Fixture();
        await fixture.account.initialize();
        addTearDown(() {
          fixture.account.dispose();
          tester.view.reset();
        });
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        await tester.pumpWidget(_app(fixture, locale: locale, scale: 2));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          find.byKey(const ValueKey('server-media-rows-section')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
