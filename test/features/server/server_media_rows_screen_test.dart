import 'dart:convert' show jsonDecode;

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/media_catalog/presentation/server_media_catalog_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

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

final class _Fixture extends AdminFixture {
  _Fixture() {
    respond = (request) async {
      if (request.url.path.endsWith('/media/catalog/target')) {
        return json(_target());
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
      return defaultResponse(request);
    };
  }

  bool failRows = false;
  int rowsReads = 0;
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
  testWidgets(
    'Core media hub renders account recent and resume rows read-only',
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
      expect(find.byType(CupertinoButton), findsNothing);
      expect(fixture.rowsReads, 1);
      final request = fixture.calls.singleWhere(
        (call) => call.url.path.endsWith('/media/rows/read'),
      );
      expect(jsonDecode(request.body), {
        'requestId': _requestId,
        'installationId': _installationId,
        'expectedInstallationRevision': 7,
      });
      semantics.dispose();
    },
  );

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
