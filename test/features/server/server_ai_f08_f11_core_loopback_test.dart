import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:larenor/features/server/ai_memory/data/server_ai_memory_api.dart';
import 'package:larenor/features/server/ai_resources/data/server_ai_resource_api.dart';
import 'package:larenor/features/server/ai_resources/domain/server_ai_resource_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/evidence_diagnostics/data/server_evidence_diagnostic_api.dart';
import 'package:larenor/features/server/mini_plugins/data/server_mini_plugin_api.dart';

import '../../../integration_test/support/synthetic_ha_server.dart';

final _coreId = 'a' * 32;
final _homeId = 'b' * 32;
final _accountId = '1' * 32;
final _jobId = '2' * 32;
final _memoryId = '3' * 32;
final _diagnosisId = '4' * 32;
final _pluginId = '5' * 32;
final _diagnosticResourceId = '9' * 32;
const _token = 'ai_final_loopback_token';

final class _AiCore {
  _AiCore._(this.server);
  final HttpServer server;
  final requests = <String>[];
  String? malformed;
  bool legacyMiniPluginContract = false;

  static Future<_AiCore> start() async {
    final value = _AiCore._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    value.server.listen(value._handle);
    return value;
  }

  String get baseUrl => 'http://127.0.0.1:${server.port}/prefix';
  Map<String, Object?> get scope => {
    'schemaVersion': 1,
    'coreId': _coreId,
    'homeId': _homeId,
  };
  Map<String, Object?> get policy => {
    'schemaVersion': 1,
    'revision': 1,
    'maxMemoryMb': 2048,
    'maxCpuPercent': 70,
    'maxConcurrentJobs': 2,
    'mediaCpuPercent': 25,
    'updatedAt': 1790755200.0,
  };
  Map<String, Object?> job({bool cancelled = false}) => {
    'schemaVersion': 1,
    'id': _jobId,
    'revision': cancelled ? 2 : 1,
    'kind': 'assistant',
    'label': 'Bounded assistant',
    'priority': 90,
    'memoryMb': 256,
    'cpuPercent': 20,
    'state': cancelled ? 'cancelled' : 'running',
    'reason': null,
    'execution': {
      'schemaVersion': 1,
      'dispatchId': '6' * 32,
      'provider': 'fixture-standalone-v1',
      'phase': cancelled ? 'cancelled' : 'running',
      'startedAt': 1790755200.0,
      'finishedAt': cancelled ? 1790755201.0 : null,
      'resultCode': cancelled ? 'cancelled' : null,
      'exitCode': cancelled ? 15 : null,
      'memoryPeakMb': 84,
      'cpuMillis': 25,
      'outputSha256': null,
      'outputBytes': null,
    },
    'ownedByCurrentSession': true,
    'createdAt': 1790755200.0,
    'updatedAt': cancelled ? 1790755201.0 : 1790755200.0,
  };
  Map<String, Object?> resourceSnapshot({bool cancelled = false}) => {
    'schemaVersion': 1,
    'scope': scope,
    'policy': policy,
    'capacity': {
      'memoryMb': 4096,
      'cpuCount': 4,
      'effectiveCpuPercent': 70,
      'allocatedMemoryMb': cancelled ? 0 : 256,
      'allocatedCpuPercent': cancelled ? 0 : 20,
      'processMemoryMb': 96,
      'systemLoadPercent': 12,
      'measuredAt': 1790755200.0,
      'mediaActive': false,
      'workerAvailable': true,
      'enforcement': 'systemdCgroupV2',
    },
    'jobs': [job(cancelled: cancelled)],
  };
  Map<String, Object?> memory({
    int revision = 1,
    String content = 'Warm kitchen light',
  }) => {
    'schemaVersion': 1,
    'memoryId': _memoryId,
    'revision': revision,
    'content': content,
    'source': {
      'schemaVersion': 1,
      'kind': 'manual',
      'description': 'Larenor memory manager',
    },
    'learnedBy': 'admin',
    'createdAt': 1790755200.0,
    'updatedAt': revision == 1 ? 1790755200.0 : 1790755201.0,
    'retention': {
      'durationSeconds': 3600,
      'expiresAt': 1790758801.0,
      'explanation': 'timeBounded',
    },
  };
  Map<String, Object?> get diagnosis => {
    'schemaVersion': 1,
    'id': _diagnosisId,
    'revision': 1,
    'createdAtMs': 1790755200000,
    'status': 'fault',
    'certainty': 'limited',
    'readOnly': true,
    'applied': false,
    'sources': [
      {
        'sourceId': 'ha-resource:$_diagnosticResourceId',
        'sourceType': 'health',
        'revision': 1,
        'capturedAtMs': 1790755200000,
        'state': 'unavailable',
        'detailRedacted': false,
        'measurements': <Object?>[],
        'events': <Object?>[],
        'provenance': 'home_assistant_history',
        'evidence': {
          'provider': 'home_assistant_history',
          'resourceId': _diagnosticResourceId,
          'resourceRevision': 1,
          'bindingId': '8' * 32,
          'bindingRevision': 1,
          'serviceId': '6' * 32,
          'serviceRevision': 1,
          'entityId': 'binary_sensor.hall_motion',
          'registryDigest': 'a' * 64,
          'historyDigest': 'b' * 64,
          'sampleCount': 16,
          'startsAtMs': 1790753400000,
          'capturedAtMs': 1790755200000,
        },
      },
    ],
    'findings': [
      {'code': 'source_unavailable'},
    ],
    'unknowns': <Object?>[],
    'recommendations': [
      {'code': 'inspect_referenced_source'},
    ],
    'redactions': [
      {'code': 'detail'},
    ],
  };
  Map<String, Object?> get limits => {
    'filesystem': {
      'mode': 'none',
      'scratchBytes': 0,
      'hostPathsAvailable': false,
    },
    'network': {'mode': 'deny_all', 'allowedDestinations': <Object?>[]},
    'compute': {
      'engine': 'wasmtime-49.0.0',
      'fuelUnitsPerInvocation': 50000,
      'epochDeadlineTicks': 1,
      'epochIncrementAfterMilliseconds': 100,
    },
    'memory': {
      'maxLinearBytes': 65536,
      'maximumMemories': 1,
      'maximumTables': 0,
    },
    'output': {'maxBytesPerInvocation': 1024},
  };
  Map<String, Object?> get runtime => {
    'artifactId': 'home-resource-count',
    'artifactVersion': 1,
    'artifactSha256': malformed == 'F11Artifact'
        ? 'c' * 64
        : '7bdd159c4e384d2413d04b0bbf6ee8b26c4ea179c089258269e44accee04a8bf',
    'manifestSha256':
        'd9d6888d352881fc02d0123160345648417621b6943c6a98212a25ced1578a28',
    'manifestSignatureAlgorithm': 'Ed25519',
    'manifestSignatureVerified': true,
    'abi': 'larenor.mini-plugin.v1',
    'engine': 'wasmtime-49.0.0',
    'allowedImports': ['larenor.current_home_resource_count()->i32'],
    'wasiEnabled': false,
  };
  Map<String, Object?> get denials => {
    'crossHomeAccess': false,
    'secretsAvailable': false,
    'hostManagementAvailable': false,
    'arbitraryCodeAvailable': false,
  };
  Map<String, Object?> plugin({bool stopped = false}) => {
    'schemaVersion': 3,
    'id': _pluginId,
    'revision': stopped ? 2 : 1,
    'templateId': 'home-resource-count',
    'displayName': 'Resource count',
    'state': stopped ? 'stopped' : 'running',
    'executionClass': 'signed_packaged_wasm_v1',
    'capabilities': ['home.resource_count.read'],
    'limits': limits,
    'denials': denials,
    'createdAt': 1790755200.0,
    'updatedAt': stopped ? 1790755201.0 : 1790755200.0,
  };

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');
    Object? body;
    if (request.method != 'GET') {
      final text = await utf8.decoder.bind(request).join();
      if (text.isNotEmpty) body = jsonDecode(text);
    }
    final ai = '/ai-resources/$_coreId/$_homeId';
    final memories = '/ai-memory/$_coreId/$_homeId';
    final diagnostics = '/evidence-diagnostics/$_coreId/$_homeId';
    final plugins = '/mini-plugins/$_coreId/$_homeId';
    if (path.endsWith('$ai/jobs/$_jobId/cancel')) {
      return _json(request, resourceSnapshot(cancelled: true));
    }
    if (path.endsWith('$ai/policy')) {
      expect((body! as Map)['expectedRevision'], 1);
      return _json(request, resourceSnapshot());
    }
    if (path.endsWith(ai)) {
      return _json(request, {
        ...resourceSnapshot(),
        if (malformed == 'F08') 'secret': true,
      });
    }
    if (path.endsWith('$memories/memories/$_memoryId/forget')) {
      return _json(request, {
        'tombstone': {'memoryId': _memoryId, 'deletedRevision': 3},
      });
    }
    if (path.endsWith('$memories/memories/$_memoryId')) {
      return _json(request, {
        'memory': memory(revision: 2, content: 'Neutral kitchen light'),
      });
    }
    if (path.endsWith('$memories/memories')) {
      return _json(request, {
        'memory': {...memory(), if (malformed == 'F09') 'secret': true},
      }, status: 201);
    }
    if (path.endsWith(memories)) {
      return _json(request, {
        'schemaVersion': 1,
        'scope': {...scope, 'accountId': _accountId},
        'memories': [memory()],
      });
    }
    if (path.endsWith('/home-resources/$_coreId/$_homeId')) {
      return _json(request, {
        'scope': scope,
        'userRevision': 1,
        'entries': [
          {
            'ref': {...scope, 'kind': 'resource', 'id': _diagnosticResourceId},
            'label': 'Hall motion',
            'order': 0,
            'revision': 1,
            'aclRevision': 1,
            'permissions': {'read': true, 'write': true},
          },
        ],
        'snapshot': 'c' * 64,
        'nextAfter': null,
      });
    }
    if (path.endsWith(
      '/admin/home-assistant/$_coreId/$_homeId/resources/'
      '$_diagnosticResourceId/binding',
    )) {
      return _json(request, {
        'binding': {
          'schemaVersion': 1,
          'id': '8' * 32,
          'revision': 1,
          'ref': {...scope, 'kind': 'resource', 'id': _diagnosticResourceId},
          'serviceId': '6' * 32,
          'serviceRevision': 1,
          'entityId': 'binary_sensor.hall_motion',
        },
      });
    }
    if (path.endsWith('$diagnostics/home-assistant-history-diagnoses') &&
        request.method == 'POST') {
      return _json(request, {
        'diagnosis': {...diagnosis, if (malformed == 'F10') 'secret': true},
      }, status: 201);
    }
    if (path.endsWith('$diagnostics/diagnoses/$_diagnosisId/repair-previews')) {
      return _json(request, {
        'repairPreview': {
          'schemaVersion': 1,
          'id': '7' * 32,
          'diagnosisId': _diagnosisId,
          'diagnosisRevision': 1,
          'createdAtMs': 1790755200000,
          'expiresAtMs': 1790755500000,
          'authorizedRole': 'admin',
          'authorizedSessionFamilyId': '8' * 32,
          'previewOnly': true,
          'applied': false,
          'executionAvailable': false,
          'steps': [
            {'code': 'inspect_referenced_source'},
          ],
        },
      });
    }
    if (path.endsWith('$plugins/catalog')) {
      return _json(request, {
        'schemaVersion': legacyMiniPluginContract ? 1 : 3,
        'catalogVersion': legacyMiniPluginContract
            ? 'mini-plugin-catalog-v1'
            : 'mini-plugin-catalog-v3',
        'templates': [
          {
            'schemaVersion': legacyMiniPluginContract ? 1 : 3,
            'id': 'home-resource-count',
            'displayName': 'Home resource count',
            'executionClass': legacyMiniPluginContract
                ? 'builtin_bounded_v1'
                : 'signed_packaged_wasm_v1',
            'capabilities': ['home.resource_count.read'],
            'limits': legacyMiniPluginContract
                ? {
                    ...limits,
                    'cpu': {'maxMillisPerInvocation': 50},
                    'memory': {'maxBytesPerInvocation': 1048576},
                  }
                : limits,
            'denials': denials,
            if (!legacyMiniPluginContract) 'runtime': runtime,
            'operations': ['render', 'stop'],
            if (malformed == 'F11') 'secret': true,
          },
        ],
      });
    }
    if (path.endsWith('$plugins/$_pluginId/render')) {
      return _json(request, {
        'result': {
          'schemaVersion': 3,
          'pluginId': _pluginId,
          'pluginRevision': 1,
          'capability': 'home.resource_count.read',
          'resourceCount': 3,
          'generatedAt': 1790755200.0,
          'networkRequests': 0,
          'filesystemBytes': 0,
          'secretReads': 0,
          'hostCapabilityCalls': 1,
          'hostManagementOperations': 0,
          'outputBytesMaximum': 1024,
          'runtimeEvidence': {
            'artifactSha256': malformed == 'F11Evidence' ? 'c' * 64 : '7bdd159c4e384d2413d04b0bbf6ee8b26c4ea179c089258269e44accee04a8bf',
            'manifestSha256': 'd9d6888d352881fc02d0123160345648417621b6943c6a98212a25ced1578a28',
            'manifestSignatureVerified': true,
            'engine': 'wasmtime-49.0.0',
            'fuelLimit': 50000,
            'fuelConsumed': 2,
            'linearMemoryLimitBytes': 65536,
            'linearMemoryBytesObserved': 65536,
            'epochDeadlineTicks': 1,
            'epochIncrementAfterMilliseconds': 100,
            'wasiEnabled': false,
            'allowedImports': ['larenor.current_home_resource_count()->i32'],
          },
        },
      });
    }
    if (path.endsWith('$plugins/$_pluginId/stop')) {
      return _json(request, {'instance': plugin(stopped: true)});
    }
    if (path.endsWith(plugins) && request.method == 'POST') {
      return _json(request, {'instance': plugin()}, status: 201);
    }
    if (path.endsWith(plugins)) {
      return _json(request, {
        'schemaVersion': 3,
        'instances': [plugin()],
        'maximumInstances': 64,
        'maximumRunning': 8,
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

Future<void> _withCore(
  Future<void> Function(_AiCore, LarenorServerApi, ServerContext) action,
) async {
  final core = await _AiCore.start();
  final transport = LarenorServerApi(
    endpoint: ServerEndpoint(core.baseUrl),
    client: IOClient(FixtureNetwork(core.server.port).createHttpClient(null)),
    timeout: const Duration(seconds: 2),
  );
  try {
    await action(core, transport, ServerContext.fromJson(core.scope));
    expect(
      core.requests.every((value) => value.contains('/prefix/api/v1/')),
      isTrue,
    );
  } finally {
    transport.close();
    await core.close();
  }
}

Matcher _invalidResponse() => throwsA(
  isA<LarenorServerException>().having(
    (error) => error.code,
    'code',
    'invalid_response',
  ),
);

void main() {
  test(
    'F08 resource client crosses loopback and rejects open envelopes',
    () => _withCore((core, transport, context) async {
      final api = ServerAiResourceApi(transport, _token, context);
      final snapshot = await api.snapshot();
      expect(snapshot.capacity.processMemoryMb, 96);
      final updated = await api.updatePolicy(
        snapshot.policy,
        AiResourcePreset.balanced,
      );
      expect(updated.policy.maxCpuPercent, 70);
      final cancelled = await api.cancel(snapshot.jobs.single);
      expect(cancelled.jobs.single.state, AiResourceJobState.cancelled);
      core.malformed = 'F08';
      await expectLater(api.snapshot(), _invalidResponse());
    }),
  );

  test(
    'F09 memory client creates corrects and forgets over loopback',
    () => _withCore((core, transport, context) async {
      final api = ServerAiMemoryApi(transport, _token, context, _accountId);
      final record = await api.remember(
        requestKey: 'memory-create-key-0001',
        content: 'Warm kitchen light',
        durationSeconds: 3600,
      );
      expect(record.retention.durationSeconds, 3600);
      final corrected = await api.correct(
        record,
        requestKey: 'memory-correct-key-0002',
        content: 'Neutral kitchen light',
        durationSeconds: 3600,
      );
      expect(corrected.revision, 2);
      await api.forget(corrected, 'memory-forget-key-0003');
      core.malformed = 'F09';
      await expectLater(
        api.remember(
          requestKey: 'memory-malformed-key-0004',
          content: 'Reject',
          durationSeconds: 3600,
        ),
        _invalidResponse(),
      );
    }),
  );

  test(
    'F10 diagnostic client reads HA history and gets preview-only repair',
    () => _withCore((core, transport, context) async {
      final api = ServerEvidenceDiagnosticApi(transport, _token, context);
      final diagnosis = await api.diagnoseServices('diagnosis-create-key-0001');
      expect(diagnosis.findingCodes, ['source_unavailable']);
      expect(diagnosis.sources.single.detailRedacted, isFalse);
      expect(diagnosis.sources.single.provenance, 'home_assistant_history');
      expect(diagnosis.sources.single.entityId, 'binary_sensor.hall_motion');
      final preview = await api.preview(
        diagnosis,
        'diagnosis-preview-key-0002',
      );
      expect(preview.stepCodes, ['inspect_referenced_source']);
      core.malformed = 'F10';
      await expectLater(
        api.diagnoseServices('diagnosis-malformed-key-0003'),
        _invalidResponse(),
      );
    }),
  );

  test(
    'F11 mini-plugin client enforces bounded catalog render and stop',
    () => _withCore((core, transport, context) async {
      final api = ServerMiniPluginApi(transport, _token, context);
      await api.catalog();
      final instance = await api.create('Resource count');
      final snapshot = await api.render(instance);
      expect(snapshot.resourceCount, 3);
      expect((await api.stop(instance)).running, isFalse);
      core.malformed = 'F11';
      await expectLater(api.catalog(), _invalidResponse());
      core.malformed = null;
      core.legacyMiniPluginContract = true;
      await expectLater(api.catalog(), _invalidResponse());
      core.legacyMiniPluginContract = false;
      core.malformed = 'F11Artifact';
      await expectLater(api.catalog(), _invalidResponse());
      core.malformed = 'F11Evidence';
      await expectLater(api.render(instance), _invalidResponse());
    }),
  );
}
