import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/ha_client/data/ha_api_exception.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';

void main() {
  const token = 'private-example-token';
  HaRestClient clientFor(
    Future<http.Response> Function(http.Request) handler, {
    String baseUrl = 'https://ha.test',
    Duration timeout = const Duration(seconds: 30),
  }) {
    final client = HaRestClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: MockClient(handler),
      requestTimeout: timeout,
    );
    addTearDown(client.dispose);
    return client;
  }

  http.Response jsonResponse(Object? value, {int status = 200}) =>
      http.Response(
        jsonEncode(value),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  test(
    'discovery endpoints retain dynamic service schemas and UTF-8 names',
    () async {
      final client = clientFor((request) async {
        expect(request.headers['Authorization'], 'Bearer $token');
        return jsonResponse(switch (request.url.path) {
          '/api/config' => {'version': '2026.8.3', 'location_name': 'Örnek ev'},
          '/api/components' => ['light', 'custom_integration'],
          '/api/events' => [
            {'event': 'custom_event', 'listener_count': 1},
          ],
          '/api/services' => [
            {
              'domain': 'custom_integration',
              'services': {
                'run': {
                  'fields': {
                    'data': {
                      'selector': {'object': {}},
                    },
                  },
                  'response': {'optional': false},
                },
              },
            },
          ],
          _ => [],
        });
      });
      expect((await client.getConfig())['location_name'], 'Örnek ev');
      expect(await client.getComponents(), contains('custom_integration'));
      expect((await client.getEvents()).single['event'], 'custom_event');
      final service = (await client.getServices()).single['services']['run'];
      expect(service['response']['optional'], isFalse);
      expect(service['fields']['data']['selector'], contains('object'));
    },
  );

  test('state CRUD has documented paths, bodies and creation status', () async {
    final methods = <String>[];
    final client = clientFor((request) async {
      methods.add(request.method);
      expect(request.url.path, '/api/states/sensor.example');
      if (request.method == 'POST') {
        expect(jsonDecode(request.body), {
          'state': '21',
          'attributes': {'unit_of_measurement': '°C'},
          'force_update': true,
        });
        return jsonResponse({
          'entity_id': 'sensor.example',
          'state': '21',
        }, status: 201);
      }
      if (request.method == 'DELETE') {
        return jsonResponse({'message': 'Entity removed.'});
      }
      return jsonResponse({'entity_id': 'sensor.example', 'state': '20'});
    });
    expect((await client.getState('sensor.example')).state, '20');
    expect(
      (await client.setState(
        'sensor.example',
        '21',
        attributes: {'unit_of_measurement': '°C'},
        forceUpdate: true,
      )).state,
      '21',
    );
    await client.deleteState('sensor.example');
    expect(methods, ['GET', 'POST', 'DELETE']);
  });

  test(
    'service response flag is presence-only and REST targets are flattened',
    () async {
      final client = clientFor((request) async {
        expect(request.url.path, '/api/services/custom_domain/run');
        expect(request.url.queryParameters, {'return_response': ''});
        expect(jsonDecode(request.body), {
          'level': 7,
          'entity_id': ['light.one', 'light.two'],
          'area_id': 'room',
        });
        return jsonResponse({
          'changed_states': [],
          'service_response': {'answer': 42},
        });
      });
      final result = await client.callServiceWithResponse(
        'custom_domain',
        'run',
        serviceData: {'level': 7},
        target: {
          'entity_id': ['light.one', 'light.two'],
          'area_id': 'room',
        },
        returnResponse: true,
      );
      expect(result['service_response']['answer'], 42);
    },
  );

  test('normal service calls omit return_response entirely', () async {
    final client = clientFor((request) async {
      expect(request.url.hasQuery, isFalse);
      return jsonResponse([
        {'entity_id': 'light.one', 'state': 'on'},
      ]);
    });
    expect(
      await client.callServiceWithResponse('light', 'turn_on'),
      hasLength(1),
    );
  });

  test(
    'template and error log preserve raw text rather than JSON decoding',
    () async {
      final client = clientFor((request) async {
        if (request.url.path == '/api/template') {
          expect(jsonDecode(request.body), {
            'template': '{{ value }}',
            'variables': {'value': 'Örnek'},
          });
          return http.Response(
            '"Örnek"\n',
            200,
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );
        }
        return http.Response('ERROR: example\nline 2', 200);
      });
      expect(
        await client.renderTemplate(
          '{{ value }}',
          variables: {'value': 'Örnek'},
        ),
        '"Örnek"\n',
      );
      expect(await client.getErrorLog(), 'ERROR: example\nline 2');
    },
  );

  test(
    'history encodes exact flag semantics and keeps compact records',
    () async {
      final start = DateTime.utc(2026, 9, 4, 9);
      final end = start.add(const Duration(hours: 1));
      final client = clientFor((request) async {
        expect(
          Uri.decodeComponent(request.url.path),
          '/api/history/period/2026-09-04T09:00:00.000Z',
        );
        expect(request.url.queryParameters, {
          'filter_entity_id': 'sensor.one,sensor.two',
          'end_time': end.toIso8601String(),
          'minimal_response': '',
          'no_attributes': '',
          'skip_initial_state': '',
          'significant_changes_only': '0',
        });
        return jsonResponse([
          [
            {'state': '20', 'last_changed': '2026-09-04T09:10:00Z'},
          ],
        ]);
      });
      final history = await client.getHistory(
        startTime: start,
        endTime: end,
        entityIds: ['sensor.one', 'sensor.two'],
        minimalResponse: true,
        noAttributes: true,
        significantChangesOnly: false,
        skipInitialState: true,
      );
      expect(history.single.single, isNot(contains('entity_id')));
    },
  );

  test(
    'false history presence flags are omitted; missing filter is rejected',
    () async {
      final client = clientFor((request) async {
        expect(request.url.queryParameters, {
          'filter_entity_id': 'sensor.one',
          'significant_changes_only': '1',
        });
        return jsonResponse([]);
      });
      await client.getHistory(entityIds: ['sensor.one']);
      await expectLater(client.getHistory(entityIds: []), throwsArgumentError);
    },
  );

  test(
    'logbook encodes context and period and rejects conflicting filters',
    () async {
      final client = clientFor((request) async {
        expect(request.url.queryParameters, {
          'context_id': 'example-context',
          'period': '2',
        });
        return jsonResponse([
          {'name': 'Example', 'when': '2026-09-04T09:00:00Z'},
        ]);
      });
      expect(
        await client.getLogbook(contextId: 'example-context', period: 2),
        hasLength(1),
      );
      await expectLater(
        client.getLogbook(entityId: 'sensor.one', contextId: 'context'),
        throwsArgumentError,
      );
    },
  );

  test(
    'calendar all-day/dateTime fields and exclusive range are preserved',
    () async {
      final start = DateTime.utc(2026, 9, 4);
      final end = start.add(const Duration(days: 1));
      final client = clientFor((request) async {
        if (request.url.path == '/api/calendars') {
          return jsonResponse([
            {'entity_id': 'calendar.example', 'name': 'Example'},
          ]);
        }
        expect(request.url.queryParameters, {
          'start': start.toIso8601String(),
          'end': end.toIso8601String(),
        });
        return jsonResponse([
          {
            'summary': 'Example',
            'start': {'date': '2026-09-04'},
            'end': {'date': '2026-09-05'},
          },
        ]);
      });
      expect(await client.getCalendars(), hasLength(1));
      expect(
        (await client.getCalendarEvents(
          'calendar.example',
          start: start,
          end: end,
        )).single['end']['date'],
        '2026-09-05',
      );
      await expectLater(
        client.getCalendarEvents('calendar.example', start: end, end: start),
        throwsArgumentError,
      );
    },
  );

  test(
    'config validation preserves an invalid result even with HTTP 200',
    () async {
      final client = clientFor((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/config/core/check_config');
        return jsonResponse({
          'result': 'invalid',
          'errors': 'Example validation error',
          'warnings': null,
        });
      });
      expect((await client.checkConfig())['result'], 'invalid');
    },
  );

  test(
    'event firing and intent use the documented payload envelopes',
    () async {
      final client = clientFor((request) async {
        if (request.url.path == '/api/events/example_event') {
          expect(jsonDecode(request.body), {'count': 2});
          return jsonResponse({'message': 'Event fired.'});
        }
        expect(request.url.path, '/api/intent/handle');
        expect(jsonDecode(request.body), {
          'name': 'ExampleIntent',
          'data': {'name': 'lamp'},
          'language': 'tr',
        });
        return jsonResponse({
          'speech': {
            'plain': {'speech': 'Example'},
          },
        });
      });
      await client.fireEvent('example_event', eventData: {'count': 2});
      expect(
        await client.handleIntent(
          'ExampleIntent',
          data: {'name': 'lamp'},
          language: 'tr',
        ),
        contains('speech'),
      );
    },
  );

  test('camera bytes are never JSON decoded', () async {
    final client = clientFor((request) async {
      expect(request.url.path, '/api/camera_proxy/camera.example');
      return http.Response.bytes([255, 216, 255, 217], 200);
    });
    expect(await client.getCameraImage('camera.example'), [255, 216, 255, 217]);
  });

  test(
    'generic methods preserve proxy prefix/query and permitted headers',
    () async {
      final client = clientFor((request) async {
        expect(request.method, 'PATCH');
        expect(request.url.path, '/prefix/api/custom/config');
        expect(request.url.queryParameters, {
          'existing': 'yes',
          'name': 'two words',
        });
        expect(request.headers['HA-Frontend-Base'], 'https://ha.test');
        expect(jsonDecode(request.body), {'enabled': false});
        return http.Response('', 204);
      }, baseUrl: ' https://ha.test/prefix/// ');
      expect(
        await client.requestJson(
          'PATCH',
          '/api/custom/config?existing=yes',
          queryParameters: {'name': 'two words'},
          headers: {'HA-Frontend-Base': 'https://ha.test'},
          body: {'enabled': false},
        ),
        isNull,
      );
    },
  );

  test(
    'generic access cannot change bearer/host or request another origin',
    () async {
      final client = clientFor(
        (_) async => fail('Invalid requests must not be sent'),
      );
      await expectLater(
        client.getJson('https://other.test/api/states'),
        throwsFormatException,
      );
      await expectLater(
        client.getJson('//other.test/api/states'),
        throwsFormatException,
      );
      await expectLater(
        client.getJson('/api/%2F..%2Fauth'),
        throwsFormatException,
      );
      await expectLater(
        client.requestJson(
          'GET',
          '/api/',
          headers: {'Authorization': 'replacement'},
        ),
        throwsArgumentError,
      );
      await expectLater(
        client.requestJson('GET', '/api/', headers: {'Host': 'other.test'}),
        throwsArgumentError,
      );
    },
  );

  test(
    'HTTP errors include status/code and redact a token echoed by a server',
    () async {
      final client = clientFor(
        (_) async => jsonResponse({'message': 'Rejected $token'}, status: 403),
      );
      await expectLater(
        client.getConfig(),
        throwsA(
          isA<HaApiException>()
              .having((error) => error.statusCode, 'status', 403)
              .having((error) => error.code, 'code', 'forbidden')
              .having(
                (error) => error.message,
                'message',
                'Rejected [redacted]',
              ),
        ),
      );
    },
  );

  test(
    'malformed successful JSON and invalid typed shapes produce API errors',
    () async {
      final client = clientFor(
        (request) async => request.url.path == '/api/config'
            ? http.Response('<html>Sign in</html>', 200)
            : jsonResponse({'unexpected': true}),
      );
      await expectLater(
        client.getConfig(),
        throwsA(
          isA<HaApiException>().having(
            (e) => e.code,
            'code',
            'invalid_response',
          ),
        ),
      );
      await expectLater(client.getStates(), throwsA(isA<HaApiException>()));
    },
  );

  test('redirects are not followed with the bearer token', () async {
    final requests = <http.Request>[];
    final client = clientFor((request) async {
      requests.add(request);
      expect(request.followRedirects, isFalse);
      return http.Response(
        '',
        302,
        headers: {'location': 'https://other.test/api/'},
      );
    });
    await expectLater(client.getConfig(), throwsA(isA<HaApiException>()));
    expect(requests, hasLength(1));
  });

  test(
    'mutation timeout is explicit and never automatically retried',
    () async {
      final response = Completer<http.Response>();
      var requests = 0;
      final client = clientFor((_) {
        requests++;
        return response.future;
      }, timeout: const Duration(milliseconds: 1));
      await expectLater(
        client.callServiceWithResponse('light', 'turn_on'),
        throwsA(isA<HaApiException>().having((e) => e.code, 'code', 'timeout')),
      );
      expect(requests, 1);
      response.complete(jsonResponse([]));
    },
  );

  test('invalid base URLs and path identifiers are rejected', () async {
    for (final url in [
      'ha.test',
      'ftp://ha.test',
      'https://user:secret@ha.test',
      'https://ha.test?token=secret',
    ]) {
      expect(
        () => HaRestClient(baseUrl: url, token: token),
        throwsFormatException,
      );
    }
    final client = clientFor(
      (_) async => fail('Invalid identifier must not be sent'),
    );
    await expectLater(client.getState('../config'), throwsFormatException);
  });
}
