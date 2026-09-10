import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'server_admin_test_support.dart';

Map<String, dynamic> providerCommandPreviewJson({
  String command = 'disable',
}) => {
  'id': 'a' * 32,
  'revision': 1,
  'installationId': 'b' * 32,
  'installationRevision': 4,
  'providerSetupId': 'c' * 32,
  'providerRevision': 3,
  'providerDomain': 'spotify',
  'command': command,
  'settings': <String, dynamic>{},
  'planHash': 'd' * 64,
  'effectAvailable': false,
  'installAvailable': false,
  'blockers': ['effect_unavailable'],
  'createdAt': '2026-09-10T10:00:00.000Z',
  'expiresAt': '2026-09-10T10:10:00.000Z',
};

Map<String, dynamic> providerCommandJson({required String requestId}) => {
  'id': 'e' * 32,
  'revision': 1,
  'requestId': requestId,
  'previewId': 'a' * 32,
  'installationId': 'b' * 32,
  'installationRevision': 4,
  'providerSetupId': 'c' * 32,
  'providerRevision': 3,
  'providerDomain': 'spotify',
  'command': 'disable',
  'state': 'blocked',
  'errorCode': 'effect_unavailable',
  'effectAvailable': false,
  'installAvailable': false,
  'createdAt': '2026-09-10T10:00:01.000Z',
};

class ProviderCommandFixture extends AdminFixture {
  ProviderCommandFixture({super.role}) {
    respond = (request) => providerResponse(request);
  }

  final providerPosts = <http.Request>[];
  Completer<http.Response>? previewResponse;
  Completer<http.Response>? confirmResponse;

  Future<http.Response> providerResponse(http.Request request) async {
    if (request.method != 'POST' ||
        !request.url.path.contains('/provider-commands')) {
      return defaultResponse(request);
    }
    providerPosts.add(request);
    if (request.url.path.endsWith('/provider-commands/previews')) {
      final command =
          (jsonDecode(request.body) as Map<String, dynamic>)['command'] as String;
      return previewResponse == null
          ? this.json(
              {'preview': providerCommandPreviewJson(command: command)},
              201,
            )
          : await previewResponse!.future;
    }
    final requestId =
        (jsonDecode(request.body) as Map<String, dynamic>)['requestId'] as String;
    return confirmResponse == null
        ? this.json(
            {'command': providerCommandJson(requestId: requestId)},
            201,
          )
        : await confirmResponse!.future;
  }
}
