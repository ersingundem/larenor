import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oikos/features/admin/data/admin_client.dart';
import 'package:oikos/features/ha_client/data/rest_client.dart';
import 'package:oikos/features/ha_client/data/ws_client.dart';

void main() {
  const baseUrl = 'http://homeassistant.local:8123';
  const token = 'test-token';

  HaAdminClient buildClient(http.Client mockHttp) {
    return HaAdminClient(
      HaRestClient(baseUrl: baseUrl, token: token, httpClient: mockHttp),
      HaWebSocketClient(baseUrl: baseUrl, token: token),
    );
  }

  test('listConfigEntries GETs the entry list and parses it', () async {
    final client = buildClient(
      MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/config/config_entries/entry');
        return http.Response(
          jsonEncode([
            {
              'entry_id': '1',
              'domain': 'hue',
              'title': 'Philips Hue',
              'source': 'user',
              'state': 'loaded',
            },
          ]),
          200,
        );
      }),
    );

    final entries = await client.listConfigEntries();
    expect(entries, hasLength(1));
    expect(entries.first.domain, 'hue');
  });

  test('deleteConfigEntry DELETEs the entry by id', () async {
    final client = buildClient(
      MockClient((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path, '/api/config/config_entries/entry/entry123');
        return http.Response('{}', 200);
      }),
    );

    await client.deleteConfigEntry('entry123');
  });

  test('reloadConfigEntry POSTs to the reload endpoint', () async {
    final client = buildClient(
      MockClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.path,
          '/api/config/config_entries/entry/entry123/reload',
        );
        return http.Response('{"require_restart": false}', 200);
      }),
    );

    await client.reloadConfigEntry('entry123');
  });

  test('listFlowHandlers GETs and sorts domain slugs', () async {
    final client = buildClient(
      MockClient((request) async {
        expect(request.url.path, '/api/config/config_entries/flow_handlers');
        return http.Response(jsonEncode(['sonos', 'hue', 'mqtt']), 200);
      }),
    );

    final handlers = await client.listFlowHandlers();
    expect(handlers, ['hue', 'mqtt', 'sonos']);
  });

  test('startFlow POSTs the handler and parses the returned step', () async {
    final client = buildClient(
      MockClient((request) async {
        expect(request.url.path, '/api/config/config_entries/flow');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['handler'], 'hue');
        return http.Response(
          jsonEncode({
            'flow_id': 'flow1',
            'type': 'form',
            'step_id': 'user',
            'data_schema': <dynamic>[],
          }),
          200,
        );
      }),
    );

    final step = await client.startFlow('hue');
    expect(step.flowId, 'flow1');
    expect(step.type, 'form');
  });

  test('submitFlowStep POSTs the submitted data to the flow id', () async {
    final client = buildClient(
      MockClient((request) async {
        expect(request.url.path, '/api/config/config_entries/flow/flow1');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['host'], '192.168.1.5');
        return http.Response(
          jsonEncode({'type': 'create_entry', 'title': 'Philips Hue'}),
          200,
        );
      }),
    );

    final step = await client.submitFlowStep('flow1', {'host': '192.168.1.5'});
    expect(step.type, 'create_entry');
  });

  test(
    'automation config CRUD hits /api/config/automation/config/<id>',
    () async {
      var callCount = 0;
      final client = buildClient(
        MockClient((request) async {
          callCount++;
          expect(request.url.path, '/api/config/automation/config/auto1');
          if (request.method == 'GET') {
            return http.Response(jsonEncode({'alias': 'Test'}), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      final config = await client.getAutomationConfig('auto1');
      expect(config['alias'], 'Test');

      await client.saveAutomationConfig('auto1', {'alias': 'Updated'});
      await client.deleteAutomationConfig('auto1');

      expect(callCount, 3);
    },
  );
}
