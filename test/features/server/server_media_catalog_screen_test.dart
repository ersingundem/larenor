import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/media_catalog/data/server_media_catalog_controller.dart';
import 'package:larenor/features/server/media_catalog/presentation/server_media_catalog_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'server_admin_test_support.dart';

const _requestId = '11111111111111111111111111111111';
const _installationId = '22222222222222222222222222222222';

Map<String, Object?> _installation() => {
  'id': _installationId,
  'requestId': '33333333333333333333333333333333',
  'preparationId': '44444444444444444444444444444444',
  'inspectionId': '55555555555555555555555555555555',
  'serviceId': 'jellyfin',
  'operationId': '66666666666666666666666666666666',
  'revision': 7,
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

Map<String, Object?> _catalog(int offset) => {
  'schemaVersion': 1,
  'installationId': _installationId,
  'installationRevision': 7,
  'snapshotRevision': 9,
  'jellyfinServiceRevision': 11,
  'offset': offset,
  'nextOffset': offset == 0 ? 1 : null,
  'total': 2,
  'items': [
    {
      'itemId': offset == 0
          ? '99999999999999999999999999999999'
          : 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'mediaKey': offset == 0 ? 'movie:tmdb:603' : 'movie:tmdb:604',
      'title': offset == 0 ? 'The Matrix' : 'The Matrix Reloaded',
      'mediaKind': 'movie',
      'runtimeSeconds': 8160,
    },
  ],
};

final class _CatalogFixture extends AdminFixture {
  _CatalogFixture() {
    respond = (request) async {
      if (request.url.path.endsWith('/admin/media/installations')) {
        if (targetGate case final gate?) await gate.future;
        return this.json({
          'installations': targetResponse ?? [_installation()],
          'nextBefore': null,
        });
      }
      if (request.url.path.endsWith('/archive-health/authority')) {
        return this.json({
          'requestId': _requestId,
          'installationId': _installationId,
          'installationRevision': 7,
          'snapshotRevision': 9,
        });
      }
      if (request.url.path.endsWith('/catalog/search')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return this.json({
          'requestId': _requestId,
          'catalog': _catalog(body['offset'] as int),
        });
      }
      return defaultResponse(request);
    };
  }

  Completer<void>? targetGate;
  List<Object?>? targetResponse;
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
          '/api/v1/admin/media/installations',
          '/api/v1/admin/media/archive-health/authority',
          '/api/v1/admin/media/archive-health/catalog/search',
          '/api/v1/admin/media/installations',
          '/api/v1/admin/media/archive-health/authority',
          '/api/v1/admin/media/archive-health/catalog/search',
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
          semantics.dispose();
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
        expect(fixture.calls, hasLength(1), reason: 'only account bootstrap');

        final field = find.byKey(
          const ValueKey('server-media-catalog-search-field'),
        );
        await tester.enterText(field, 'matrix');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(find.text('The Matrix'), findsOneWidget);
        expect(fixture.mutations, hasLength(2));
        final next = find.byKey(const ValueKey('server-media-catalog-next'));
        await tester.scrollUntilVisible(
          next,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.getRect(next).height, greaterThanOrEqualTo(48));
        expect(tester.getSemantics(next).flagsCollection.isButton, isTrue);
        Focus.of(tester.element(find.text('The Matrix'))).requestFocus();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.tap(next);
        await tester.pumpAndSettle();
        expect(find.text('The Matrix Reloaded'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

String _fixedRequestId() => _requestId;
