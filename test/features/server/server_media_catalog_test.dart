import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_catalog/data/server_media_catalog_api.dart';
import 'package:larenor/features/server/media_catalog/data/server_media_catalog_controller.dart';
import 'package:larenor/features/server/media_catalog/domain/server_media_catalog_models.dart';

import 'server_admin_test_support.dart';

const _requestId = '11111111111111111111111111111111';
const _installationId = '22222222222222222222222222222222';

Map<String, Object?> _catalog() => {
  'schemaVersion': 1,
  'installationId': _installationId,
  'installationRevision': 7,
  'snapshotRevision': 9,
  'jellyfinServiceRevision': 11,
  'offset': 0,
  'nextOffset': 1,
  'total': 2,
  'items': const [
    {
      'itemId': '33333333333333333333333333333333',
      'mediaKey': 'movie:tmdb:603',
      'title': 'The Matrix',
      'mediaKind': 'movie',
      'runtimeSeconds': 8160,
    },
  ],
};

final class _CatalogFixture extends AdminFixture {
  _CatalogFixture() {
    respond = (request) async {
      if (request.url.path.endsWith('/media/catalog/target')) {
        return this.json({
          'schemaVersion': 1,
          'installationId': _installationId,
          'installationRevision': 7,
          'snapshotRevision': 9,
          'jellyfinServiceRevision': 11,
        });
      }
      if (request.url.path.endsWith('/catalog/search')) {
        return pending?.future ??
            this.json({'requestId': _requestId, 'catalog': _catalog()});
      }
      return defaultResponse(request);
    };
  }

  Completer<http.Response>? pending;
}

void main() {
  test('uses member target handshake and bounded body-only search', () async {
    final calls = <http.Request>[];
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.test'),
      client: MockClient((request) async {
        calls.add(request);
        if (request.url.path.endsWith('/media/catalog/target')) {
          expect(request.method, 'GET');
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'installationId': _installationId,
              'installationRevision': 7,
              'snapshotRevision': 9,
              'jellyfinServiceRevision': 11,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(request.url.query, isEmpty);
        expect(body, {
          'requestId': _requestId,
          'installationId': _installationId,
          'expectedInstallationRevision': 7,
          'expectedSnapshotRevision': 9,
          'query': 'matrix',
          'mediaKind': 'movie',
          'offset': 0,
          'limit': 24,
        });
        return http.Response(
          jsonEncode({'requestId': _requestId, 'catalog': _catalog()}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(api.close);

    final page =
        await ServerMediaCatalogApi(
          api,
          'synthetic-access',
          requestId: () => _requestId,
        ).search(
          installationId: _installationId,
          expectedInstallationRevision: 7,
          query: 'matrix',
          mediaKind: ServerMediaCatalogKind.movie,
        );

    expect(page.items.single.title, 'The Matrix');
    expect(page.snapshotRevision, 9);
    expect(page.query, 'matrix');
    expect(page.mediaKind, ServerMediaCatalogKind.movie);
    expect(calls.map((call) => call.url.path), [
      '/api/v1/media/catalog/target',
      '/api/v1/media/catalog/search',
    ]);

    final callsBeforeMismatch = calls.length;
    await expectLater(
      ServerMediaCatalogApi(
        api,
        'synthetic-access',
        requestId: () => _requestId,
      ).searchCurrent(
        query: 'matrix',
        mediaKind: ServerMediaCatalogKind.episode,
        offset: 1,
        previousPage: page,
      ),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'invalid_request',
        ),
      ),
    );
    expect(calls, hasLength(callsBeforeMismatch));
  });

  test('invalid query and secret-bearing response fail closed', () async {
    var calls = 0;
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.test'),
      client: MockClient((request) async {
        calls++;
        if (request.url.path.endsWith('/media/catalog/target')) {
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'installationId': _installationId,
              'installationRevision': 7,
              'snapshotRevision': 9,
              'jellyfinServiceRevision': 11,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'requestId': _requestId,
            'catalog': {..._catalog(), 'accessToken': 'secret'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(api.close);
    final client = ServerMediaCatalogApi(
      api,
      'synthetic-access',
      requestId: () => _requestId,
    );

    await expectLater(
      client.search(
        installationId: _installationId,
        expectedInstallationRevision: 7,
        query: ' matrix',
      ),
      throwsA(isA<LarenorServerException>()),
    );
    expect(calls, 0);
    await expectLater(
      client.searchCurrent(query: ' matrix'),
      throwsA(isA<LarenorServerException>()),
    );
    expect(calls, 0);
    await expectLater(
      client.search(
        installationId: _installationId,
        expectedInstallationRevision: 7,
        query: 'matrix\u202e',
      ),
      throwsA(isA<LarenorServerException>()),
    );
    expect(calls, 0);
    await expectLater(
      client.search(
        installationId: _installationId,
        expectedInstallationRevision: 7,
        query: 'matrix',
      ),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });

  test('target schema version is an exact integer', () async {
    var calls = 0;
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.test'),
      client: MockClient((request) async {
        calls++;
        return request.method == 'GET'
            ? http.Response(
                jsonEncode({
                  'schemaVersion': 1.0,
                  'installationId': _installationId,
                  'installationRevision': 7,
                  'snapshotRevision': 9,
                  'jellyfinServiceRevision': 11,
                }),
                200,
                headers: {'content-type': 'application/json'},
              )
            : http.Response(
                jsonEncode({'requestId': _requestId, 'catalog': _catalog()}),
                200,
                headers: {'content-type': 'application/json'},
              );
      }),
    );
    addTearDown(api.close);

    await expectLater(
      ServerMediaCatalogApi(
        api,
        'synthetic-access',
        requestId: () => _requestId,
      ).searchCurrent(query: 'matrix'),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
    expect(calls, 1);
  });

  test('account loss retires a delayed catalog result', () async {
    final fixture = _CatalogFixture()..pending = Completer<http.Response>();
    await fixture.account.initialize();
    final controller = ServerMediaCatalogController(
      fixture.account,
      requestId: () => _requestId,
    );
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);

    final pending = controller.search(
      installationId: _installationId,
      expectedInstallationRevision: 7,
      query: 'matrix',
      current: () => true,
    );
    await Future<void>.delayed(Duration.zero);
    await fixture.account.signOut();
    fixture.pending!.complete(
      fixture.json({'requestId': _requestId, 'catalog': _catalog()}),
    );
    await pending;

    expect(controller.page, isNull);
    expect(controller.failure, isNull);
    expect(controller.busy, false);
  });

  test('route retirement discards a delayed catalog result', () async {
    final fixture = _CatalogFixture()..pending = Completer<http.Response>();
    await fixture.account.initialize();
    final controller = ServerMediaCatalogController(
      fixture.account,
      requestId: () => _requestId,
    );
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    var current = true;

    final pending = controller.search(
      installationId: _installationId,
      expectedInstallationRevision: 7,
      query: 'matrix',
      current: () => current,
    );
    await Future<void>.delayed(Duration.zero);
    current = false;
    fixture.pending!.complete(
      fixture.json({'requestId': _requestId, 'catalog': _catalog()}),
    );
    await pending;

    expect(controller.page, isNull);
    expect(controller.failure, isNull);
    expect(controller.busy, false);
  });
}
