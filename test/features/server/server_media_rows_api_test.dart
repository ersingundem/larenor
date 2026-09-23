import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_rows/data/server_media_rows_api.dart';
import 'package:larenor/features/server/media_rows/domain/server_media_rows_models.dart';

const _requestId = '11111111111111111111111111111111';
const _installationId = '22222222222222222222222222222222';
const _itemId = '33333333333333333333333333333333';

Map<String, Object?> _response() => {
  'requestId': _requestId,
  'installationId': _installationId,
  'installationRevision': 7,
  'bindingRevision': 4,
  'rows': {
    'schemaVersion': 1,
    'revision': 9,
    'recent': [
      {
        'itemId': _itemId,
        'title': 'The Matrix',
        'mediaKind': 'movie',
        'addedAt': 2000000000,
        'runtimeSeconds': 8160,
        'positionSeconds': 0,
      },
    ],
    'resume': [
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

void main() {
  test('reads strict account rows through the current Core target', () async {
    final calls = <http.Request>[];
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.test'),
      client: MockClient((request) async {
        calls.add(request);
        expect(request.headers['authorization'], 'Bearer synthetic-access');
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'installationId': _installationId,
              'installationRevision': 7,
              'snapshotRevision': 8,
              'jellyfinServiceRevision': 9,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        expect(request.url.query, isEmpty);
        if (request.url.path.endsWith('/media/rows/target')) {
          expect(jsonDecode(request.body), {
            'installationId': _installationId,
            'expectedInstallationRevision': 7,
          });
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'installationId': _installationId,
              'installationRevision': 7,
              'bindingRevision': 4,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        expect(jsonDecode(request.body), {
          'requestId': _requestId,
          'installationId': _installationId,
          'expectedInstallationRevision': 7,
          'expectedBindingRevision': 4,
        });
        return http.Response(
          jsonEncode(_response()),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(api.close);

    final result = await ServerMediaRowsApi(
      api,
      'synthetic-access',
      requestId: () => _requestId,
    ).readCurrent();

    expect(result.bindingRevision, 4);
    expect(result.rows.revision, 9);
    expect(result.rows.recent.single.title, 'The Matrix');
    expect(result.rows.resume.single.kind, ServerMediaRowKind.episode);
    expect(result.rows.resume.single.progress, 0.25);
    expect(calls.map((call) => call.url.path), [
      '/api/v1/media/catalog/target',
      '/api/v1/media/rows/target',
      '/api/v1/media/rows/read',
    ]);
    expect(calls.last.body, isNot(contains('token')));
    expect(calls.last.body, isNot(contains('user')));
  });

  test('rejects secret fields, incoherent lanes and changed authority', () {
    expect(
      () => ServerMediaRowsTarget.fromJson(
        {
          'schemaVersion': 1,
          'installationId': _installationId,
          'installationRevision': 7,
          'bindingRevision': 4,
          'userId': 'must-not-cross-boundary',
        },
        expectedInstallationId: _installationId,
        expectedInstallationRevision: 7,
      ),
      throwsFormatException,
    );
    for (final invalid in <Map<String, Object?>>[
      {
        'schemaVersion': 1.0,
        'installationId': _installationId,
        'installationRevision': 7,
        'bindingRevision': 4,
      },
      {
        'schemaVersion': 1,
        'installationId': '55555555555555555555555555555555',
        'installationRevision': 7,
        'bindingRevision': 4,
      },
      {
        'schemaVersion': 1,
        'installationId': _installationId,
        'installationRevision': 8,
        'bindingRevision': 4,
      },
      {
        'schemaVersion': 1,
        'installationId': _installationId,
        'installationRevision': 7,
        'bindingRevision': 4.0,
      },
      {
        'schemaVersion': 1,
        'installationId': _installationId,
        'installationRevision': 7,
        'bindingRevision': true,
      },
      {
        'schemaVersion': 1,
        'installationId': _installationId,
        'installationRevision': 7,
        'bindingRevision': 0,
      },
    ]) {
      expect(
        () => ServerMediaRowsTarget.fromJson(
          invalid,
          expectedInstallationId: _installationId,
          expectedInstallationRevision: 7,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => ServerAccountMediaRows.fromJson(
        {..._response(), 'apiKey': 'must-not-cross-boundary'},
        expectedRequestId: _requestId,
        expectedInstallationId: _installationId,
        expectedInstallationRevision: 7,
        expectedBindingRevision: 4,
      ),
      throwsFormatException,
    );
    expect(
      () => ServerAccountMediaRows.fromJson(
        _response(),
        expectedRequestId: _requestId,
        expectedInstallationId: _installationId,
        expectedInstallationRevision: 7,
        expectedBindingRevision: 5,
      ),
      throwsFormatException,
    );
    final misplaced = _response();
    final rows = misplaced['rows']! as Map<String, Object?>;
    final resume = rows['resume']! as List<Object?>;
    (resume.single as Map<String, Object?>)['positionSeconds'] = 0;
    expect(
      () => ServerAccountMediaRows.fromJson(
        misplaced,
        expectedRequestId: _requestId,
        expectedInstallationId: _installationId,
        expectedInstallationRevision: 7,
        expectedBindingRevision: 4,
      ),
      throwsFormatException,
    );
    expect(
      () => ServerAccountMediaRows.fromJson(
        _response(),
        expectedRequestId: _requestId,
        expectedInstallationId: _installationId,
        expectedInstallationRevision: 8,
        expectedBindingRevision: 4,
      ),
      throwsFormatException,
    );
    for (final unsafe in ['\u00ad', '\u061c', '\u200b', '\u200d', '\u2060']) {
      final hidden = _response();
      final hiddenRows = hidden['rows']! as Map<String, Object?>;
      final recent = hiddenRows['recent']! as List<Object?>;
      (recent.single as Map<String, Object?>)['title'] = 'The${unsafe}Matrix';
      expect(
        () => ServerAccountMediaRows.fromJson(
          hidden,
          expectedRequestId: _requestId,
          expectedInstallationId: _installationId,
          expectedInstallationRevision: 7,
          expectedBindingRevision: 4,
        ),
        throwsFormatException,
        reason: 'Unicode category C character must fail closed',
      );
    }
  });

  test('retired caller stops before and after Core reads', () async {
    var calls = 0;
    var current = true;
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.test'),
      client: MockClient((request) async {
        calls++;
        if (request.method == 'GET') {
          current = false;
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'installationId': _installationId,
              'installationRevision': 7,
              'snapshotRevision': 8,
              'jellyfinServiceRevision': 9,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(jsonEncode(_response()), 200);
      }),
    );
    addTearDown(api.close);
    final client = ServerMediaRowsApi(
      api,
      'synthetic-access',
      requestId: () => _requestId,
    );

    await expectLater(
      client.readCurrent(current: () => false),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'retired',
        ),
      ),
    );
    expect(calls, 0);
    await expectLater(
      client.readCurrent(current: () => current),
      throwsA(isA<LarenorServerException>()),
    );
    expect(calls, 1);
  });

  for (final retirePath in <String>[
    '/api/v1/media/rows/target',
    '/api/v1/media/rows/read',
  ]) {
    test('retired caller discards $retirePath response', () async {
      var current = true;
      final calls = <String>[];
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://core.test'),
        client: MockClient((request) async {
          calls.add(request.url.path);
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'schemaVersion': 1,
                'installationId': _installationId,
                'installationRevision': 7,
                'snapshotRevision': 8,
                'jellyfinServiceRevision': 9,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.url.path.endsWith('/media/rows/target')) {
            if (retirePath == request.url.path) current = false;
            return http.Response(
              jsonEncode({
                'schemaVersion': 1,
                'installationId': _installationId,
                'installationRevision': 7,
                'bindingRevision': 4,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (retirePath == request.url.path) current = false;
          return http.Response(
            jsonEncode(_response()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(api.close);

      await expectLater(
        ServerMediaRowsApi(
          api,
          'synthetic-access',
          requestId: () => _requestId,
        ).readCurrent(current: () => current),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'retired',
          ),
        ),
      );
      expect(calls, [
        '/api/v1/media/catalog/target',
        '/api/v1/media/rows/target',
        if (retirePath.endsWith('/read')) '/api/v1/media/rows/read',
      ]);
    });
  }

  test('invalid target response never reaches rows read', () async {
    final calls = <String>[];
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.test'),
      client: MockClient((request) async {
        calls.add(request.url.path);
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'installationId': _installationId,
              'installationRevision': 7,
              'snapshotRevision': 8,
              'jellyfinServiceRevision': 9,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'schemaVersion': 1,
            'installationId': _installationId,
            'installationRevision': 7,
            'bindingRevision': 0,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(api.close);

    await expectLater(
      ServerMediaRowsApi(
        api,
        'synthetic-access',
        requestId: () => _requestId,
      ).readCurrent(),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
    expect(calls, [
      '/api/v1/media/catalog/target',
      '/api/v1/media/rows/target',
    ]);
  });
}
