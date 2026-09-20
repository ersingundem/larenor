import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_api.dart';
import 'package:larenor/features/home_resources/data/core_bounded_upload_file_access.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'home_resources_fixture.dart';

HomeResourceRecord _target() {
  final fixture = contract();
  return HomeResourcePage.fromJson(
    fixture['adminList'],
    expectedContext: ServerContext.fromJson(fixture['context']),
  ).entries.firstWhere((entry) => entry.kind == HomeResourceKind.resource);
}

Future<({HttpServer server, ServerEndpoint endpoint})> _loopback(
  Future<void> Function(HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  return (
    server: server,
    endpoint: ServerEndpoint('http://127.0.0.1:${server.port}'),
  );
}

Map<String, Object> _descriptor({int revision = 4}) => {
  'resourceId': '3' * 32,
  'serviceRevision': revision,
  'contentLength': 7,
  'sha256': sha256.convert(utf8.encode('payload')).toString(),
  'contentType': 'text/plain; charset=utf-8',
  'createdAt': 1789911000.25,
  'updatedAt': 1789911001.5,
};

void main() {
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = null);

  test('descriptor consumes the exact closed product contract', () async {
    final fixture = await _loopback((request) async {
      expect(request.method, 'GET');
      expect(
        request.uri.path,
        '/api/v1/home-resources/${'a' * 32}/${'b' * 32}/${'3' * 32}/blob/descriptor',
      );
      expect(request.uri.query, isEmpty);
      expect(request.headers.value('authorization'), 'Bearer token');
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'blob': _descriptor()}));
      await request.response.close();
    });
    addTearDown(() => fixture.server.close(force: true));
    final api = CoreBoundedDownloadApi(endpoint: fixture.endpoint);
    addTearDown(api.close);

    final value = await api.descriptor(token: 'token', target: _target());

    expect(value.resourceId, '3' * 32);
    expect(value.serviceRevision, 4);
    expect(value.contentLength, 7);
    expect(value.toString(), 'CoreBoundedBlobDescriptor');
  });

  test('upload sends only bounded bytes and exact authority headers', () async {
    final payload = Uint8List.fromList(utf8.encode('payload'));
    final requestId = '8' * 32;
    final fixture = await _loopback((request) async {
      expect(request.method, 'PUT');
      expect(
        request.uri.path,
        '/api/v1/home-resources/${'a' * 32}/${'b' * 32}/${'3' * 32}/blob/uploads/$requestId',
      );
      expect(request.uri.query, isEmpty);
      expect(request.headers.value('authorization'), 'Bearer token');
      expect(
        request.headers.value('content-type'),
        'text/plain; charset=utf-8',
      );
      expect(request.headers.value('content-length'), '7');
      expect(request.headers.value('x-larenor-upload-request-id'), requestId);
      expect(
        request.headers.value('x-larenor-content-sha256'),
        sha256.convert(payload).toString(),
      );
      expect(request.headers.value('x-larenor-expected-user-revision'), '7');
      expect(
        request.headers.value('x-larenor-expected-resource-revision'),
        '1',
      );
      expect(request.headers.value('x-larenor-expected-acl-revision'), '2');
      expect(request.headers.value('x-larenor-expected-service-revision'), '4');
      expect(
        await request.fold<List<int>>(
          <int>[],
          (all, part) => all..addAll(part),
        ),
        payload,
      );
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'blob': {'requestId': requestId, ..._descriptor(revision: 5)},
          }),
        );
      await request.response.close();
    });
    addTearDown(() => fixture.server.close(force: true));
    final api = CoreBoundedDownloadApi(
      endpoint: fixture.endpoint,
      requestId: () => requestId,
    );
    addTearDown(api.close);

    final result = await api.upload(
      token: 'token',
      target: _target(),
      expectedUserRevision: 7,
      expectedServiceRevision: 4,
      source: CoreBoundedUploadSource(
        filename: 'note.txt',
        contentType: 'text/plain; charset=utf-8',
        bytes: payload,
      ),
    );

    expect(result.requestId, requestId);
    expect(result.descriptor.serviceRevision, 5);
    expect(
      result.descriptor.authenticates(result.sourceDigest, payload.length),
      isTrue,
    );
  });

  test('descriptor and upload reject malformed or stale envelopes', () async {
    var calls = 0;
    final fixture = await _loopback((request) async {
      calls++;
      await request.drain<void>();
      request.response
        ..statusCode = request.method == 'GET' ? 200 : 409
        ..headers.contentType = ContentType.json
        ..write(
          request.method == 'GET'
              ? jsonEncode({
                  'blob': {..._descriptor(), 'privatePath': '/secret'},
                })
              : '{"error":{"code":"revision_conflict","message":"secret"}}',
        );
      await request.response.close();
    });
    addTearDown(() => fixture.server.close(force: true));
    final api = CoreBoundedDownloadApi(endpoint: fixture.endpoint);
    addTearDown(api.close);

    await expectLater(
      api.descriptor(token: 'token', target: _target()),
      throwsA(
        isA<CoreBoundedDownloadException>().having(
          (e) => e.code,
          'code',
          'invalid_response',
        ),
      ),
    );
    await expectLater(
      api.upload(
        token: 'token',
        target: _target(),
        expectedUserRevision: 7,
        expectedServiceRevision: 4,
        source: CoreBoundedUploadSource(
          filename: 'note.txt',
          contentType: 'text/plain',
          bytes: Uint8List.fromList([1]),
        ),
      ),
      throwsA(
        isA<CoreBoundedDownloadException>()
            .having((e) => e.code, 'code', 'revision_conflict')
            .having((e) => e.toString(), 'redacted', isNot(contains('secret'))),
      ),
    );
    expect(calls, 2);
  });

  test(
    'file selection is bounded, copied and maps a closed MIME set',
    () async {
      final original = Uint8List.fromList([1, 2, 3]);
      final access = CoreBoundedUploadFileAccess(
        pick: () async => CoreBoundedPickedFile(
          name: 'manual.PDF',
          declaredLength: 3,
          chunks: Stream.value(original),
        ),
      );

      final selected = await access.pick();
      original[0] = 9;

      expect(selected!.filename, 'manual.PDF');
      expect(selected.contentType, 'application/pdf');
      expect(selected.bytes, [1, 2, 3]);
      expect(selected.toString(), 'CoreBoundedUploadSource');
    },
  );

  test('file selection rejects changed, empty and oversized sources', () async {
    for (final picked in [
      CoreBoundedPickedFile(
        name: 'a.bin',
        declaredLength: 2,
        chunks: Stream.value(Uint8List.fromList([1])),
      ),
      CoreBoundedPickedFile(
        name: 'a.bin',
        declaredLength: 0,
        chunks: const Stream.empty(),
      ),
      CoreBoundedPickedFile(
        name: 'a.bin',
        declaredLength: CoreBoundedDownloadApi.maxBlobBytes + 1,
        chunks: const Stream.empty(),
      ),
    ]) {
      final access = CoreBoundedUploadFileAccess(pick: () async => picked);
      await expectLater(
        access.pick(),
        throwsA(isA<CoreBoundedDownloadException>()),
      );
    }
  });
}
