import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/habit_anomalies/data/server_habit_anomaly_api.dart';

import '../../../integration_test/support/synthetic_ha_server.dart';

final _coreId = 'a' * 32;
final _homeId = 'b' * 32;
final _observationId = '7' * 32;
const _token = 'habit_loopback_access_token';

final class _HabitCore {
  _HabitCore._(this.server);
  final HttpServer server;
  final requests = <String>[];
  bool malformed = false;
  Map? observationBody;

  static Future<_HabitCore> start() async {
    final value = _HabitCore._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    value.server.listen(value._handle);
    return value;
  }

  String get baseUrl => 'http://127.0.0.1:${server.port}/prefix';

  Map<String, Object?> service(String id, String state) => {
    'id': id,
    'name': 'Synthetic service',
    'kind': 'home_assistant',
    'baseUrl': 'https://service.invalid',
    'revision': 1,
    'credentialKeys': ['token'],
    'verification': {
      'state': state,
      'checkedAt': state == 'never' ? null : '2026-09-30T08:00:00Z',
      'version': null,
    },
  };

  Map<String, Object?> report({String? feedback}) => {
    'schemaVersion': 1,
    'seriesId': 'service_unavailable_count',
    'metric': 'service_unavailable_count',
    'unit': 'count',
    'modelVersion': 'robust-mad-v1',
    'classification': 'anomaly',
    'unknownReason': null,
    'sampleCount': 13,
    'minimumBaselineSamples': 12,
    'current': {
      'observationId': _observationId,
      'value': 1,
      'observedAtMs': 1790755200000,
      'feedback': feedback,
    },
    'baseline': {'sampleCount': 12, 'center': 0, 'tolerance': 0.001},
    'missingDataIsUnknown': true,
  };

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');
    Object? body;
    if (request.method != 'GET') {
      final text = await utf8.decoder.bind(request).join();
      if (text.isNotEmpty) body = jsonDecode(text);
    }
    if (path.endsWith('/admin/services') && request.method == 'GET') {
      return _json(request, {
        'services': [service('3' * 32, 'never'), service('4' * 32, 'never')],
      });
    }
    if (path.endsWith('/admin/services/${'3' * 32}/check')) {
      return _json(request, {'service': service('3' * 32, 'reachable')});
    }
    if (path.endsWith('/admin/services/${'4' * 32}/check')) {
      return _json(request, {'service': service('4' * 32, 'unavailable')});
    }
    final root = '/habit-anomalies/$_coreId/$_homeId';
    if (path.endsWith('$root/observations')) {
      observationBody = body as Map;
      return _json(request, {'report': report()}, status: 201);
    }
    if (path.endsWith('$root/observations/$_observationId/feedback')) {
      expect((body! as Map)['label'], 'false_positive');
      return _json(request, {'report': report(feedback: 'false_positive')});
    }
    if (path.endsWith(root) && request.method == 'GET') {
      return _json(request, {
        'schemaVersion': 1,
        'scope': {'schemaVersion': 1, 'coreId': _coreId, 'homeId': _homeId},
        'reports': [
          {...report(), if (malformed) 'secret': 'must-reject'},
        ],
      });
    }
    request.response.statusCode = 404;
    return _json(request, {
      'error': {'code': 'not_found'},
    });
  }

  Future<void> _json(
    HttpRequest request,
    Object value, {
    int status = 200,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(value));
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  test(
    'F07 production client observes services and marks anomaly over loopback',
    () async {
      final core = await _HabitCore.start();
      final transport = LarenorServerApi(
        endpoint: ServerEndpoint(core.baseUrl),
        client: IOClient(
          FixtureNetwork(core.server.port).createHttpClient(null),
        ),
        timeout: const Duration(seconds: 2),
      );
      addTearDown(() async {
        transport.close();
        await core.close();
      });
      final api = ServerHabitAnomalyApi(
        transport,
        _token,
        ServerContext.fromJson({
          'schemaVersion': 1,
          'coreId': _coreId,
          'homeId': _homeId,
        }),
      );
      final observed = await api.observeServices('habit-observe-key-0001');
      expect(observed.classification, 'anomaly');
      expect(core.observationBody!['value'], 1);
      expect(core.observationBody!['observedAtMs'], 1790755200000);
      final marked = await api.mark(
        observed,
        'false_positive',
        'habit-feedback-key-0001',
      );
      expect(marked.current.feedback, 'false_positive');
      expect(
        core.requests.every((value) => value.contains('/prefix/api/v1/')),
        isTrue,
      );

      core.malformed = true;
      await expectLater(
        api.snapshot(),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    },
  );
}
