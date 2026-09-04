import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/data/ha_api_exception.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/admin/data/admin_client.dart';
import 'package:larenor/features/ha_tools/domain/ha_action.dart';

/// Run manually with HA_URL and HA_TOKEN environment variables, or
/// --config /private/path/to/config.json containing baseUrl and token.
/// Prints only aggregate counts; HTTP writes are blocked by the transport.
Future<void> main(List<String> args) async {
  final Map<String, dynamic> config;
  try {
    if (args.length == 2 && args.first == '--config') {
      config = jsonDecode(
        await File(args.last).readAsString(),
      ) as Map<String, dynamic>;
    } else {
      config = {
        'baseUrl': Platform.environment['HA_URL'],
        'token': Platform.environment['HA_TOKEN'],
      };
    }
  } catch (_) {
    stderr.writeln('Could not read the private audit configuration.');
    exitCode = 64;
    return;
  }
  if (config['baseUrl'] is! String || config['token'] is! String) {
    stderr.writeln(
      'Set HA_URL and HA_TOKEN, or pass --config with a private JSON file.',
    );
    exitCode = 64;
    return;
  }
  final rest = HaRestClient(
    baseUrl: config['baseUrl'],
    token: config['token'],
    httpClient: _ReadOnlyHttpClient(),
  );
  final ws = HaWebSocketClient(
    baseUrl: config['baseUrl'],
    token: config['token'],
  );
  final admin = HaAdminClient(rest, ws);
  final results = <String, dynamic>{};
  Future<void> read(String name, Future<Object?> Function() fn) async {
    try {
      results[name] = await fn();
    } catch (e) {
      results[name] = {
        'error': e.runtimeType.toString(),
        if (e is HaApiException) 'code': e.code,
        if (e is HaApiException) 'status': e.statusCode,
      };
    }
  }

  try {
    await read('rest_config', () async => (await rest.getConfig())['version']);
    await read('action_schema', () async {
      final actions = HaAction.parseCatalog(await rest.getServices());
      final fields = actions.expand((action) => action.fields).toList();
      return {
        'actions': actions.length,
        'fields': fields.length,
        'responses': actions.where((a) => a.supportsResponse).length,
      };
    });
    final states = await rest.getStates();
    results['state_models'] = states.length;
    final sample =
        states.where((entity) => entity.domain == 'sensor').firstOrNull ??
        states.firstOrNull;
    if (sample != null) {
      await read('rest_state', () async {
        await rest.getState(sample.entityId);
        return 'ok';
      });
      final now = DateTime.now();
      await read(
        'rest_history',
        () async => (await rest.getHistory(
          entityIds: [sample.entityId],
          startTime: now.subtract(const Duration(minutes: 30)),
          endTime: now,
        )).length,
      );
      await read(
        'rest_logbook',
        () async => (await rest.getLogbook(
          entityId: sample.entityId,
          startTime: now.subtract(const Duration(minutes: 30)),
          endTime: now,
        )).length,
      );
    }
    await read(
      'admin_entries',
      () async => (await admin.listConfigEntries()).length,
    );
    await read(
      'admin_flow_handlers',
      () async => (await admin.listFlowHandlers()).length,
    );
    ws.connect();
    await ws.status
        .firstWhere((status) => status == HaConnectionStatus.connected)
        .timeout(const Duration(seconds: 15));
    await read(
      'ws_config',
      () async => (await ws.sendCommand({'type': 'get_config'}))['version'],
    );
    await read('ws_devices', () async => (await admin.listDevices()).length);
    await read('ws_areas', () async => (await admin.listAreas()).length);
    await read(
      'ws_entity_registry',
      () async => (await admin.listEntityRegistry()).length,
    );
    await read(
      'ws_panels',
      () async => (await ws.sendCommand({'type': 'get_panels'}) as Map).length,
    );
    await read('ws_event_subscription', () async {
      final subscription = await ws.subscribeEvents(eventType: 'state_changed');
      final listener = subscription.events.listen(
        (_) {},
        onError: (Object _) {},
      );
      await subscription.cancel();
      await listener.cancel();
      return 'acknowledged and unsubscribed';
    });
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(results));
    if (results.values.any(
      (value) => value is Map && value.containsKey('error'),
    )) {
      exitCode = 1;
    }
  } finally {
    rest.dispose();
    ws.dispose();
  }
}

/// Prevent accidental writes when extending this audit later.
class _ReadOnlyHttpClient extends http.BaseClient {
  final _inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method != 'GET') {
      throw StateError('Read-only audit rejected an HTTP write.');
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
