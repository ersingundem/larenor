import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/camera_search/data/camera_search_api.dart';
import 'package:larenor/features/camera_search/domain/camera_search_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'camera_search_api_test.dart' as support;

void main() {
  final bytes = File('server/tests/support/assets/f41_clip.mp4')
      .readAsBytesSync();
  final evidence = CameraSearchPage.fromJson(
    support.pageJson(),
    support.context(),
  ).results.single.evidence;
  test('fixed authenticated clip endpoint verifies bytes, scope and content digest', () async {
    late http.Request request;
    final transport = LarenorServerApi(
      endpoint: support.session().endpoint,
      client: MockClient((value) async {
        request = value;
        return http.Response.bytes(
          bytes,
          200,
          headers: {
            'content-type': 'video/mp4',
            'x-larenor-content-sha256': sha256.convert(bytes).toString(),
            'x-larenor-clip-id': evidence.clipId,
          },
        );
      }),
    );
    addTearDown(transport.close);
    final api = CameraSearchApi(
      transport,
      support.session(),
      isCurrent: () => true,
    );
    expect(await api.clip(evidence), orderedEquals(bytes));
    expect(request.method, 'POST');
    expect(
      request.url.path,
      '/api/v1/camera-search/${'a' * 32}/${'b' * 32}/clip',
    );
    expect(
      request.headers['authorization'],
      'Bearer ${support.session().accessToken}',
    );
    expect(jsonDecode(request.body)['eventId'], evidence.eventId);
    expect(request.url.query, isEmpty);
  });
  for (final invalid in ['digest', 'scope', 'mime', 'redirect']) {
    test('invalid $invalid media never reaches player', () async {
      final transport = LarenorServerApi(
        endpoint: support.session().endpoint,
        client: MockClient(
          (_) async => http.Response.bytes(
            bytes,
            invalid == 'redirect' ? 302 : 200,
            headers: {
              'content-type': invalid == 'mime' ? 'text/html' : 'video/mp4',
              'x-larenor-content-sha256': invalid == 'digest'
                  ? '0' * 64
                  : sha256.convert(bytes).toString(),
              'x-larenor-clip-id': invalid == 'scope'
                  ? '0' * 32
                  : evidence.clipId,
              if (invalid == 'redirect')
                'location': 'https://provider.invalid/private',
            },
          ),
        ),
      );
      addTearDown(transport.close);
      final api = CameraSearchApi(
        transport,
        support.session(),
        isCurrent: () => true,
      );
      await expectLater(
        api.clip(evidence),
        throwsA(isA<LarenorServerException>()),
      );
    });
  }
  test('retirement cancels ongoing camera transfer', () async {
    final ready = Completer<http.Response>();
    final transport = LarenorServerApi(
      endpoint: support.session().endpoint,
      client: MockClient((_) => ready.future),
    );
    addTearDown(transport.close);
    final api = CameraSearchApi(
      transport,
      support.session(),
      isCurrent: () => true,
    );
    final loading = api.clip(evidence);
    final rejected = expectLater(
      loading,
      throwsA(isA<LarenorServerException>()),
    );
    api.retire();
    ready.complete(
      http.Response.bytes(
        bytes,
        200,
        headers: {
          'content-type': 'video/mp4',
          'x-larenor-content-sha256': sha256.convert(bytes).toString(),
          'x-larenor-clip-id': evidence.clipId,
        },
      ),
    );
    await rejected;
  });
}
