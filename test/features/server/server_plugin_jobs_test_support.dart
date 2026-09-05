import 'dart:convert';

import 'package:http/http.dart' as http;

import 'server_plugins_test_support.dart';

Map<String, dynamic> pluginJobJson({String state = 'queued', int revision = 1}) {
  final plan = pluginPreviewJson()['preview']['plan'];
  return {
    'id': 'a' * 32,
    'revision': revision,
    'operation': 'preflight',
    'previewId': 'd' * 32,
    'requestId': 'e' * 32,
    'serviceId': plan['serviceId'],
    'distributionId': plan['distributionId'],
    'planHash': plan['planHash'],
    'platform': plan['image']['platform'],
    'state': state,
    'phase': state == 'queued' ? 'queued' : state == 'running' ? 'checking_requirements' : 'complete',
    'cancelRequested': state == 'cancelled',
    'createdAt': '2026-09-05T09:00:00.000Z',
    'updatedAt': '2026-09-05T09:00:01.000Z',
    'result': state == 'succeeded' ? {
      'catalogDigest': plan['catalogDigest'],
      'planHash': plan['planHash'],
      'platform': plan['image']['platform'],
      'checkedAt': '2026-09-05T09:00:01.000Z',
      'checks': [
        {'code': 'platform', 'status': 'passed', 'rootId': null, 'availableMiB': null, 'requiredMiB': null},
        {'code': 'storage_capacity', 'status': 'failed', 'rootId': 'appdata', 'availableMiB': 1, 'requiredMiB': 1024},
        {'code': 'port_availability', 'status': 'unknown', 'rootId': null, 'availableMiB': null, 'requiredMiB': null},
      ],
    } : null,
    'errorCode': state == 'failed' ? 'worker_unavailable' : state == 'needs_attention' ? 'authority_changed' : null,
  };
}

Map<String, dynamic> pluginJobEventJson({int sequence = 1, String code = 'job_queued', int revision = 1}) => {
  'sequence': sequence,
  'code': code,
  'createdAt': '2026-09-05T09:00:00.000Z',
  'jobRevision': revision,
};

class PluginJobsFixture extends PluginsFixture {
  PluginJobsFixture({super.role, super.mustChange});
  bool configured = true;
  Map<String, dynamic> job = pluginJobJson();
  @override
  http.Response pluginResponse(http.Request request) {
    final path = request.url.path;
    if (path.endsWith('/jobs/capabilities')) {
      return this.json({'preflightConfigured': configured, 'installAvailable': false});
    }
    if (path.endsWith('/jobs') && request.method == 'GET') {
      return this.json({'jobs': [job], 'nextBefore': null});
    }
    if (path.endsWith('/jobs') && request.method == 'POST') {
      final body = jsonDecode(request.body);
      job = {...job, 'requestId': body['requestId']};
      return this.json({'job': job}, 202);
    }
    if (path.endsWith('/events')) {
      return this.json({'events': request.url.queryParameters['after'] == '0' ? [pluginJobEventJson()] : [], 'nextAfter': null});
    }
    if (path.endsWith('/cancel')) {
      job = {...pluginJobJson(state: 'cancelled', revision: job['revision'] + 1), 'requestId': job['requestId']};
      return this.json({'job': job});
    }
    if (path.endsWith('/jobs/${job['id']}')) return this.json({'job': job});
    return super.pluginResponse(request);
  }
}
