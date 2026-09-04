import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/admin/data/admin_client.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';

import 'admin_test_fakes.dart';

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
    'options and reconfigure use distinct endpoints and frontend-base header',
    () async {
      final requests = <http.Request>[];
      final client = buildClient(
        MockClient((request) async {
          requests.add(request);
          expect(request.headers['HA-Frontend-Base'], baseUrl);
          return http.Response('{"type":"form","flow_id":"flow1"}', 200);
        }),
      );
      await client.startFlow('hue', entryId: 'entry1');
      await client.startFlow('entry1', options: true);
      await client.submitFlowStep('flow1', {'delay': 5}, options: true);
      await client.getFlow('flow1', options: true);
      expect(requests.map((request) => request.url.path), [
        '/api/config/config_entries/flow',
        '/api/config/config_entries/options/flow',
        '/api/config/config_entries/options/flow/flow1',
        '/api/config/config_entries/options/flow/flow1',
      ]);
      expect(jsonDecode(requests[0].body), {
        'handler': 'hue',
        'entry_id': 'entry1',
      });
      expect(jsonDecode(requests[1].body), {'handler': 'entry1'});
      expect(jsonDecode(requests[2].body), {'delay': 5});
      expect(requests[3].method, 'GET');
    },
  );

  test(
    'registry updates retain explicit null clearing and use official commands',
    () async {
      final socket = RecordingAdminSocket();
      final client = fakeAdminClient(socket);
      await client.createArea('Kitchen');
      await client.updateArea('kitchen', 'Dining');
      await client.deleteArea('kitchen');
      await client.updateDevice('hub', {'name_by_user': null, 'area_id': null});
      await client.updateEntity('light.old', {
        'new_entity_id': 'light.new',
        'disabled_by': null,
        'hidden_by': 'user',
      });
      await client.updateConfigEntry('entry', {'title': 'New name'});
      await client.setConfigEntryDisabled('entry', true);
      expect(socket.commands, [
        {'type': 'config/area_registry/create', 'name': 'Kitchen'},
        {
          'type': 'config/area_registry/update',
          'area_id': 'kitchen',
          'name': 'Dining',
        },
        {'type': 'config/area_registry/delete', 'area_id': 'kitchen'},
        {
          'type': 'config/device_registry/update',
          'device_id': 'hub',
          'name_by_user': null,
          'area_id': null,
        },
        {
          'type': 'config/entity_registry/update',
          'entity_id': 'light.old',
          'new_entity_id': 'light.new',
          'disabled_by': null,
          'hidden_by': 'user',
        },
        {
          'type': 'config_entries/update',
          'entry_id': 'entry',
          'title': 'New name',
        },
        {
          'type': 'config_entries/disable',
          'entry_id': 'entry',
          'disabled_by': 'user',
        },
      ]);
    },
  );

  test(
    'pending discovery and reauth flows come from the server progress command',
    () async {
      final socket = RecordingAdminSocket(
        respond: (_) => [
          {
            'flow_id': 'reauth1',
            'handler': 'cloud',
            'context': {'source': 'reauth'},
          },
        ],
      );
      final flows = await fakeAdminClient(socket).getPendingFlows();
      expect(socket.commands.single, {'type': 'config_entries/flow/progress'});
      expect(flows.single['flow_id'], 'reauth1');
    },
  );

  test('reload and delete preserve server restart requirement', () async {
    final client = buildClient(
      MockClient((_) async => http.Response('{"require_restart":true}', 200)),
    );
    expect(await client.reloadConfigEntry('entry'), isTrue);
    expect(await client.deleteConfigEntry('entry'), isTrue);
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
