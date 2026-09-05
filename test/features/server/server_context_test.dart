import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const _access = 'synthetic_context_access_token';
const _privatePayload = 'synthetic-private-payload';

Matcher _failure(String code) => isA<LarenorServerException>()
    .having((error) => error.code, 'code', code)
    .having(
      (error) => error.toString(),
      'redacted error',
      allOf(isNot(contains(_access)), isNot(contains(_privatePayload))),
    );

http.Response _json(Object? value, {int status = 200}) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  final fixture = jsonDecode(
    File('contracts/core-context.v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final valid = fixture['validResponses'] as List;
  final invalid = fixture['invalidResponses'] as List;
  final payload = valid.first['value'] as Map<String, dynamic>;

  for (final sample in valid) {
    test('shared valid context: ${sample['name']}', () {
      final value = sample['value'] as Map<String, dynamic>;
      final context = ServerContext.fromJson(value);
      expect(context.schemaVersion, 1);
      expect(context.coreId, value['coreId']);
      expect(context.homeId, value['homeId']);
      expect(context.toJson(), value);
      expect(ServerContext.fromJson(context.toJson()), context);
    });
  }

  for (final sample in invalid) {
    test('shared invalid context: ${sample['name']}', () {
      expect(
        () => ServerContext.fromJson(sample['value']),
        throwsA(_failure('invalid_response')),
      );
    });
  }

  test('context is a value object independent of mutable wire maps', () {
    final source = Map<String, dynamic>.from(payload);
    final context = ServerContext.fromJson(source);
    final same = ServerContext.fromJson(Map<String, dynamic>.from(source));
    source['coreId'] = 'a' * 32;
    final changedCore = ServerContext.fromJson(source);
    final changedHome = ServerContext.fromJson({
      ...payload,
      'homeId': 'b' * 32,
    });
    context.toJson()['homeId'] = 'c' * 32;
    expect(context.coreId, payload['coreId']);
    expect(context.homeId, payload['homeId']);
    expect(context, same);
    expect(context, isNot(changedCore));
    expect(context, isNot(changedHome));
    expect(context, isNot(payload));
    expect({context, same, changedCore, changedHome}, hasLength(3));
    expect(context.toString(), 'ServerContext');
  });

  test(
    'context GET keeps proxy prefix and sends only bearer authorization',
    () async {
      var calls = 0;
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://fixture.invalid/larenor/'),
        client: MockClient((request) async {
          calls++;
          expect(request.method, 'GET');
          expect(
            request.url.toString(),
            'https://fixture.invalid/larenor/api/v1/context',
          );
          expect(request.url.query, isEmpty);
          expect(request.bodyBytes, isEmpty);
          expect(request.headers['authorization'], 'Bearer $_access');
          expect(request.headers['accept'], 'application/json');
          expect(request.followRedirects, isFalse);
          return _json(payload);
        }),
      );
      addTearDown(api.close);
      expect((await api.context(_access)).toJson(), payload);
      expect(calls, 1);
    },
  );

  test(
    'every invalid shared payload fails through the HTTP method too',
    () async {
      var index = 0;
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://fixture.invalid'),
        client: MockClient((_) async => _json(invalid[index++]['value'])),
      );
      addTearDown(api.close);
      for (final _ in invalid) {
        await expectLater(
          api.context(_access),
          throwsA(_failure('invalid_response')),
        );
      }
      expect(index, invalid.length);
    },
  );

  for (final status in [401, 403, 404, 429, 503]) {
    test(
      'context HTTP $status is a static failure without fallback or retry',
      () async {
        var calls = 0;
        final api = LarenorServerApi(
          endpoint: ServerEndpoint('https://fixture.invalid'),
          client: MockClient((_) async {
            calls++;
            return _json({
              'error': {'code': _privatePayload, 'message': _access},
            }, status: status);
          }),
        );
        addTearDown(api.close);
        final code = switch (status) {
          401 => 'unauthorized',
          403 => 'forbidden',
          404 => 'context_endpoint_unavailable',
          429 => 'rate_limited',
          _ => 'server_error',
        };
        await expectLater(api.context(_access), throwsA(_failure(code)));
        expect(calls, 1);
      },
    );
  }

  test(
    'context 404 from a proxy is localized without exposing its HTML',
    () async {
      var calls = 0;
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://fixture.invalid/larenor/'),
        client: MockClient((request) async {
          calls++;
          expect(request.url.path, '/larenor/api/v1/context');
          return http.Response(
            '<html>$_privatePayload $_access</html>',
            404,
            headers: {'content-type': 'text/html'},
          );
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.context(_access),
        throwsA(_failure('context_endpoint_unavailable')),
      );
      expect(calls, 1);
    },
  );

  for (final target in [
    (method: 'GET', path: '/auth/me', query: <String, String>{}),
    (method: 'POST', path: '/context', query: <String, String>{}),
    (method: 'GET', path: '/context/other', query: <String, String>{}),
    (method: 'GET', path: '/context', query: {'limit': '1'}),
  ]) {
    test('only exact context GET maps 404: $target', () async {
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://fixture.invalid/prefix'),
        client: MockClient(
          (_) async => _json({
            'error': {
              'code': 'context_endpoint_unavailable',
              'message': _privatePayload,
            },
          }, status: 404),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.request(
          target.method,
          target.path,
          token: _access,
          queryParameters: target.query,
        ),
        throwsA(_failure('server_error')),
      );
    });
  }

  test('context 404 classification keeps the error-body byte bound', () async {
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://fixture.invalid'),
      client: MockClient((_) async => http.Response('x' * 8193, 404)),
    );
    addTearDown(api.close);
    await expectLater(
      api.context(_access),
      throwsA(_failure('invalid_response')),
    );
  });

  for (final status in [200, 401, 503]) {
    test(
      'server body cannot spoof the local context failure at HTTP $status',
      () async {
        final api = LarenorServerApi(
          endpoint: ServerEndpoint('https://fixture.invalid'),
          client: MockClient(
            (_) async => _json({
              'error': {
                'code': 'context_endpoint_unavailable',
                'message': _privatePayload,
              },
            }, status: status),
          ),
        );
        addTearDown(api.close);
        await expectLater(
          api.context(_access),
          throwsA(
            _failure(switch (status) {
              200 => 'invalid_response',
              401 => 'unauthorized',
              _ => 'server_error',
            }),
          ),
        );
      },
    );
  }

  test(
    'initial-password denial is retained without accepting a context',
    () async {
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://fixture.invalid'),
        client: MockClient(
          (_) async => _json({
            'error': {
              'code': 'password_change_required',
              'message': _privatePayload,
            },
          }, status: 403),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.context(_access),
        throwsA(_failure('password_change_required')),
      );
    },
  );

  test('redirects, wrong content type, malformed JSON and invalid UTF8 are rejected', () async {
    final responses = [
      http.Response(
        '',
        307,
        headers: {'location': 'https://untrusted.invalid/$_access'},
      ),
      http.Response(
        jsonEncode(payload),
        200,
        headers: {'content-type': 'text/html'},
      ),
      http.Response(
        '{"schemaVersion":',
        200,
        headers: {'content-type': 'application/json'},
      ),
      http.Response.bytes(
        [0xff],
        200,
        headers: {'content-type': 'application/json'},
      ),
    ];
    var calls = 0;
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://fixture.invalid'),
      client: MockClient((_) async => responses[calls++]),
    );
    addTearDown(api.close);
    await expectLater(
      api.context(_access),
      throwsA(_failure('connection_failed')),
    );
    for (var i = 0; i < 3; i++) {
      await expectLater(
        api.context(_access),
        throwsA(_failure('invalid_response')),
      );
    }
    expect(calls, responses.length);
  });

  for (final declared in [true, false]) {
    test(
      'context enforces response byte limit with declared length $declared',
      () async {
        var calls = 0;
        final api = LarenorServerApi(
          endpoint: ServerEndpoint('https://fixture.invalid'),
          client: MockClient.streaming((_, _) async {
            calls++;
            return http.StreamedResponse(
              Stream.fromIterable([
                if (declared)
                  utf8.encode(jsonEncode(payload))
                else
                  List<int>.filled(LarenorServerApi.maxJsonBytes, 32),
                if (!declared) [32],
              ]),
              200,
              contentLength: declared
                  ? LarenorServerApi.maxJsonBytes + 1
                  : null,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        addTearDown(api.close);
        await expectLater(
          api.context(_access),
          throwsA(_failure('invalid_response')),
        );
        expect(calls, 1);
      },
    );
  }

  test(
    'context timeout never retries or turns a late response into success',
    () async {
      final pending = Completer<http.Response>();
      var calls = 0;
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://fixture.invalid'),
        timeout: const Duration(milliseconds: 20),
        client: MockClient((_) {
          calls++;
          return pending.future;
        }),
      );
      addTearDown(api.close);
      await expectLater(api.context(_access), throwsA(_failure('timeout')));
      pending.complete(_json(payload));
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
    },
  );

  test(
    'closing transport cancels a pending context and rejects later calls',
    () async {
      final pending = Completer<http.Response>();
      final entered = Completer<void>();
      var calls = 0;
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://fixture.invalid'),
        client: MockClient((_) {
          calls++;
          entered.complete();
          return pending.future;
        }),
      );
      addTearDown(api.close);
      final result = api.context(_access);
      await entered.future;
      api.close();
      pending.complete(_json(payload));
      await expectLater(result, throwsA(_failure('cancelled')));
      await expectLater(api.context(_access), throwsA(_failure('cancelled')));
      expect(calls, 1);
    },
  );
}
