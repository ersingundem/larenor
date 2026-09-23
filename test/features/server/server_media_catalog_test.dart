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
  'nextOffset': null,
  'total': 1,
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
      if (request.url.path.endsWith('/authority')) {
        return this.json({
          'requestId': _requestId,
          'installationId': _installationId,
          'installationRevision': 7,
          'snapshotRevision': 9,
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
  test('performs authority handshake and bounded body-only search', () async {
    final calls = <http.Request>[];
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.test'),
      client: MockClient((request) async {
        calls.add(request);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (request.url.path.endsWith('/authority')) {
          expect(body, {
            'requestId': _requestId,
            'installationId': _installationId,
            'expectedInstallationRevision': 7,
          });
          return http.Response(
            jsonEncode({
              'requestId': _requestId,
              'installationId': _installationId,
              'installationRevision': 7,
              'snapshotRevision': 9,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
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
    expect(calls.map((call) => call.url.path), [
      '/api/v1/admin/media/archive-health/authority',
      '/api/v1/admin/media/archive-health/catalog/search',
    ]);
  });

  test('invalid query and secret-bearing response fail closed', () async {
    var calls = 0;
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.test'),
      client: MockClient((request) async {
        calls++;
        if (request.url.path.endsWith('/authority')) {
          return http.Response(
            jsonEncode({
              'requestId': _requestId,
              'installationId': _installationId,
              'installationRevision': 7,
              'snapshotRevision': 9,
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
}
