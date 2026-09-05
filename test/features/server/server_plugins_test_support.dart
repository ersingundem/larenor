import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'server_admin_test_support.dart';

Map<String, dynamic> pluginFixtureJson() =>
    jsonDecode(File('test/fixtures/server_plugins.v1.json').readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic> pluginCatalogJson() =>
    pluginFixtureJson()['catalog'] as Map<String, dynamic>;

Map<String, dynamic> pluginPreviewJson({
  String service = 'jellyfin',
  String platform = 'linux/amd64',
  bool custom = false,
  DateTime? now,
}) {
  final choices = (pluginFixtureJson()['plans'] as List).where(
    (value) => value['serviceId'] == service && value['platform'] == platform,
  );
  final item = custom ? choices.last : choices.first;
  final created = now ?? DateTime.now().toUtc();
  return {
    'preview': {
      'id': 'd' * 32,
      'revision': 1,
      'createdAt': created.toIso8601String(),
      'expiresAt': created.add(const Duration(minutes: 10)).toIso8601String(),
      'plan': item['plan'],
    },
  };
}

class PluginsFixture extends AdminFixture {
  PluginsFixture({super.role, super.mustChange}) {
    respond = (request) async => pluginResponse(request);
  }
  http.Response pluginResponse(http.Request request) {
    if (request.method == 'GET' &&
        request.url.path.endsWith('/plugins/catalog')) {
      return this.json(pluginCatalogJson());
    }
    if (request.method == 'POST' &&
        request.url.path.endsWith('/plugins/previews')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final settings = body['settings'] as Map<String, dynamic>;
      final defaultName = body['serviceId'].toString().replaceAll('_', '-');
      return this.json(
        pluginPreviewJson(
          service: body['serviceId'],
          platform: body['platform'],
          custom: settings['instanceName'] != defaultName,
        ),
        201,
      );
    }
    if (request.method == 'GET' &&
        request.url.path.endsWith('/admin/services')) {
      return this.json({'services': []});
    }
    return defaultResponse(request);
  }
}
