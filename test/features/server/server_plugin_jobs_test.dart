import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/plugins/data/server_plugin_jobs_api.dart';
import 'package:larenor/features/server/plugins/data/server_plugin_jobs_controller.dart';
import 'package:larenor/features/server/plugins/domain/server_plugin_job_models.dart';
import 'package:larenor/features/server/plugins/domain/server_plugin_models.dart';

import 'server_plugin_jobs_test_support.dart';
import 'server_plugins_test_support.dart';

void main() {
  final invalid = throwsA(
    isA<LarenorServerException>().having(
      (e) => e.code,
      'code',
      'invalid_response',
    ),
  );
  test(
    'all durable states parse and completion retains failed and unknown checks',
    () {
      for (final state in [
        'queued',
        'running',
        'succeeded',
        'failed',
        'cancelled',
        'needs_attention',
      ]) {
        final job = ServerPluginJob.fromJson(pluginJobJson(state: state));
        expect(job.active, state == 'queued' || state == 'running');
        if (state == 'succeeded') {
          expect(job.result!.checks.map((c) => c.status), [
            'passed',
            'failed',
            'unknown',
          ]);
          expect(() => job.result!.checks.clear(), throwsUnsupportedError);
        }
      }
    },
  );
  final bad = <String, void Function(Map<String, dynamic>)>{
    'unknown secret': (v) => v['token'] = 'synthetic-secret',
    'missing required nullable': (v) => v.remove('result'),
    'unknown job operation': (v) => v['operation'] = 'install',
    'unknown service': (v) => v['serviceId'] = 'untrusted-image',
    'unknown distribution': (v) => v['distributionId'] = 'external',
    'uppercase identity': (v) => v['id'] = 'A' * 32,
    'floating revision': (v) => v['revision'] = 1.0,
    'negative revision': (v) => v['revision'] = -1,
    'invalid calendar date': (v) => v['updatedAt'] = '2026-02-30T09:00:01.000Z',
    'non UTC timestamp': (v) =>
        v['updatedAt'] = '2026-09-05T12:00:01.000+03:00',
    'time reversal': (v) => v['updatedAt'] = '2026-09-04T09:00:01.000Z',
    'queued cancellation': (v) => v['cancelRequested'] = true,
    'queued complete phase': (v) => v['phase'] = 'complete',
    'queued error': (v) => v['errorCode'] = 'worker_unavailable',
    'succeeded missing result': (v) {
      v['state'] = 'succeeded';
      v['phase'] = 'complete';
    },
    'cancelled without requested cancellation': (v) {
      v['state'] = 'cancelled';
      v['phase'] = 'complete';
    },
  };
  for (final sample in bad.entries) {
    test('job rejects ${sample.key}', () {
      final json = pluginJobJson();
      sample.value(json);
      expect(() => ServerPluginJob.fromJson(json), invalid);
    });
  }
  for (final sample in <String, void Function(Map<String, dynamic>)>{
    'wrong plan': (v) => v['planHash'] = 'f' * 64,
    'wrong platform': (v) => v['platform'] = 'linux/arm64',
    'empty checks': (v) => v['checks'] = [],
    'too many checks': (v) => v['checks'] = List.filled(33, v['checks'][0]),
    'unknown status': (v) => v['checks'][0]['status'] = 'installed',
    'absolute host path': (v) => v['checks'][1]['rootId'] = '/mnt/media',
    'secret payload': (v) => v['checks'][0]['message'] = 'synthetic-secret',
    'negative capacity': (v) => v['checks'][1]['availableMiB'] = -1,
    'floating capacity': (v) => v['checks'][1]['availableMiB'] = 3.5,
  }.entries) {
    test('result rejects ${sample.key}', () {
      final json = pluginJobJson(state: 'succeeded');
      sample.value(json['result']);
      expect(() => ServerPluginJob.fromJson(json), invalid);
    });
  }
  test(
    'capabilities never accept installation availability or secret fields',
    () {
      expect(
        ServerPluginJobCapabilities.fromJson({
          'preflightConfigured': true,
          'installAvailable': false,
        }).preflightConfigured,
        isTrue,
      );
      expect(
        () => ServerPluginJobCapabilities.fromJson({
          'preflightConfigured': true,
          'installAvailable': true,
        }),
        invalid,
      );
      expect(
        () => ServerPluginJobCapabilities.fromJson({
          'preflightConfigured': true,
          'installAvailable': false,
          'socket': '/secret',
        }),
        invalid,
      );
    },
  );

  group('guarded jobs API and controller', () {
    late PluginJobsFixture f;
    late ServerPluginJobsController controller;
    setUp(() async {
      f = PluginJobsFixture();
      await f.account.initialize();
      controller = ServerPluginJobsController(
        f.account,
        requestId: () => 'e' * 32,
      );
    });
    tearDown(() {
      controller.dispose();
      f.account.dispose();
    });
    ServerPluginPreview preview() =>
        ServerPluginPreview.fromJson(pluginPreviewJson()['preview']);
    test('history is available without a worker; launch is disabled', () async {
      f.configured = false;
      await controller.load(current: () => true);
      expect(controller.jobs, hasLength(1));
      expect(controller.capabilities!.preflightConfigured, isFalse);
      await controller.launch(preview(), current: () => true);
      expect(f.mutations, isEmpty);
    });
    test(
      'create is explicitly requested and binds returned request and plan',
      () async {
        await controller.load(current: () => true);
        expect(f.mutations, isEmpty);
        await controller.launch(preview(), current: () => true);
        expect(controller.selected!.requestId, 'e' * 32);
        expect(jsonDecode(f.mutations.single.body), {
          'operation': 'preflight',
          'previewId': 'd' * 32,
          'expectedRevision': 1,
          'planHash': preview().plan.planHash,
          'requestId': 'e' * 32,
        });
        expect(f.calls.any((r) => r.url.path.contains('/install')), isFalse);
      },
    );
    test(
      'uncertain create retains the same request for manual recovery only',
      () async {
        await controller.load(current: () => true);
        var writes = 0;
        f.respond = (request) async {
          if (request.method == 'POST' && request.url.path.endsWith('/jobs')) {
            writes++;
            if (writes == 1) throw http.ClientException('synthetic-secret');
          }
          return f.pluginResponse(request);
        };
        await controller.launch(preview(), current: () => true);
        expect(controller.canRetryLaunch, isTrue);
        expect(writes, 1);
        await controller.launch(preview(), current: () => true);
        expect(writes, 1);
        await controller.retryLaunch(current: () => true);
        expect(writes, 2);
        final bodies = f.mutations.map((r) => jsonDecode(r.body)).toList();
        expect(bodies[1], bodies[0]);
        expect(controller.selected, isNotNull);
      },
    );
    test('stale account response cannot expose history or restore pending requests', () async {
      final held = Completer<http.Response>();
      f.respond = (request) => request.url.path.endsWith('/jobs')
          ? held.future
          : Future.value(f.pluginResponse(request));
      final loading = controller.load(current: () => true);
      await Future<void>.delayed(Duration.zero);
      controller.invalidate();
      held.complete(
        f.json({
          'jobs': [pluginJobJson()],
          'nextBefore': null,
        }),
      );
      await loading;
      expect(controller.jobs, isEmpty);
      expect(controller.capabilities, isNull);
      expect(controller.canRetryLaunch, isFalse);
    });
    test(
      'a proxy 502 after commit preserves the original recovery identity',
      () async {
        await controller.load(current: () => true);
        var writes = 0;
        f.respond = (request) async {
          if (request.method == 'POST' && request.url.path.endsWith('/jobs')) {
            writes++;
            if (writes == 1) return http.Response('synthetic-secret', 502);
          }
          return f.pluginResponse(request);
        };
        await controller.launch(preview(), current: () => true);
        expect(controller.failure, 'server_error');
        expect(controller.canRetryLaunch, isTrue);
        expect(writes, 1);
        await controller.retryLaunch(current: () => true);
        expect(writes, 2);
        expect(f.mutations.elementAt(1).body, f.mutations.first.body);
        expect(controller.selected, isNotNull);
      },
    );
    test('API rejects mismatched selected identity, secret errors and unsafe cursor pages', () async {
      await f.account.withSession((api, session) async {
        final jobs = ServerPluginJobsApi(api, session.accessToken);
        f.respond = (_) async => f.json({
          'job': {...pluginJobJson(), 'id': 'b' * 32},
        });
        await expectLater(jobs.get('a' * 32), invalid);
        f.respond = (_) async => f.json({
          'jobs': [pluginJobJson(), pluginJobJson()],
          'nextBefore': null,
        });
        await expectLater(jobs.list(), invalid);
        f.respond = (_) async => f.json({
          'events': [
            pluginJobEventJson(sequence: 2),
            pluginJobEventJson(sequence: 1),
          ],
          'nextAfter': null,
        });
        await expectLater(jobs.events('a' * 32), invalid);
      });
    });
    test(
      'cancel uses the current selected revision and never starts installation',
      () async {
        await controller.load(current: () => true);
        await controller.select(controller.jobs.single, current: () => true);
        await controller.cancelSelected(current: () => true);
        expect(jsonDecode(f.mutations.single.body), {'expectedRevision': 1});
        expect(controller.selected!.state, 'cancelled');
        expect(controller.selected!.active, isFalse);
      },
    );
  });
}
