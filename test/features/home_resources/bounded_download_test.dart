import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/home_resources/data/core_bounded_download_api.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'home_resources_fixture.dart';

Uint8List frame(String trace, int sequence, bool finalFrame, List<int> payload) {
  final result = BytesBuilder(copy: false);
  result.add(ascii.encode('LRB1'));
  result.add(ascii.encode(trace));
  final fields = ByteData(13)
    ..setUint64(0, sequence)
    ..setUint8(8, finalFrame ? 1 : 0)
    ..setUint32(9, payload.length);
  result.add(fields.buffer.asUint8List());
  result.add(payload);
  return result.takeBytes();
}

HomeResourceRecord target() {
  final fixture = contract();
  return HomeResourcePage.fromJson(
    fixture['memberList'],
    expectedContext: ServerContext.fromJson(fixture['context']),
  ).entries.last;
}

Future<({HttpServer server, ServerEndpoint endpoint})> loopback(
  Future<void> Function(HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  return (
    server: server,
    endpoint: ServerEndpoint('http://127.0.0.1:${server.port}'),
  );
}

void main() {
  test('real loopback HTTP validates exact metadata and framed UTF-8 payload', () async {
    final payload = utf8.encode('Larenor Türkçe tanılama');
    final trace = '1' * 32;
    final body = BytesBuilder(copy: false)
      ..add(frame(trace, 0, false, payload.sublist(0, 7)))
      ..add(frame(trace, 1, false, payload.sublist(7)))
      ..add(frame(trace, 2, true, const []));
    final wire = body.takeBytes();
    final fixture = await loopback((request) async {
      expect(request.method, 'POST');
      expect(
        request.uri.path,
        '/api/v1/home-resources/${'a' * 32}/${'b' * 32}/${'3' * 32}/blob',
      );
      expect(request.headers.value('authorization'), 'Bearer synthetic-token');
      expect(request.headers.value('range'), isNull);
      expect(request.headers.value('if-range'), isNull);
      expect(jsonDecode(await utf8.decoder.bind(request).join()), {
        'expectedUserRevision': 7,
        'expectedRevision': 1,
        'expectedAclRevision': 2,
        'expectedServiceRevision': 4,
        'deadlineMs': 5000,
      });
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType(
          'application',
          'vnd.larenor.blob-stream.v1',
        )
        ..headers.set('x-larenor-trace-id', trace)
        ..headers.set('x-larenor-blob-content-length', payload.length)
        ..headers.set('x-larenor-blob-sha256', sha256.convert(payload).toString())
        ..headers.set('x-larenor-blob-content-type', 'text/plain; charset=utf-8')
        ..headers.set('x-larenor-service-revision', 4)
        ..headers.set('accept-ranges', 'none')
        ..contentLength = wire.length
        ..add(wire);
      await request.response.close();
    });
    addTearDown(() => fixture.server.close(force: true));
    final api = CoreBoundedDownloadApi(
      endpoint: fixture.endpoint,
      client: http.Client(),
    );
    addTearDown(api.close);

    final result = await api.download(
      token: 'synthetic-token',
      target: target(),
      expectedUserRevision: 7,
      expectedServiceRevision: 4,
    );

    expect(result.bytes, payload);
    expect(result.traceId, trace);
    expect(result.contentType, 'text/plain; charset=utf-8');
    expect(result.sha256, sha256.convert(payload).toString());
    expect(result.serviceRevision, 4);
    expect(result.toString(), 'CoreBoundedBlob');
  });

  for (final entry in {
    401: 'unauthorized',
    403: 'forbidden',
    409: 'revision_conflict',
    408: 'timeout',
  }.entries) {
    test('HTTP ${entry.key} stays distinct and response secrets are discarded', () async {
      final fixture = await loopback((request) async {
        request.response
          ..statusCode = entry.key
          ..headers.contentType = ContentType.json
          ..write('{"error":{"code":"private-secret","message":"private-secret"}}');
        await request.response.close();
      });
      addTearDown(() => fixture.server.close(force: true));
      final api = CoreBoundedDownloadApi(endpoint: fixture.endpoint);
      addTearDown(api.close);
      await expectLater(
        api.download(
          token: 'synthetic-token',
          target: target(),
          expectedUserRevision: 7,
          expectedServiceRevision: 4,
        ),
        throwsA(
          isA<CoreBoundedDownloadException>()
              .having((error) => error.code, 'code', entry.value)
              .having((error) => error.toString(), 'safe', isNot(contains('private'))),
        ),
      );
    });
  }

  for (final mode in ['sequence', 'late', 'digest', 'truncated', 'oversize']) {
    test('rejects $mode stream before exposing bytes', () async {
      final payload = utf8.encode('fixture');
      final trace = '2' * 32;
      final data = switch (mode) {
        'sequence' => frame(trace, 1, false, payload),
        'late' => Uint8List.fromList([
          ...frame(trace, 0, true, const []),
          ...frame(trace, 1, false, payload),
        ]),
        'truncated' => frame(trace, 0, false, payload).sublist(0, 51),
        _ => Uint8List.fromList([
          ...frame(trace, 0, false, payload),
          ...frame(trace, 1, true, const []),
        ]),
      };
      final fixture = await loopback((request) async {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType('application', 'vnd.larenor.blob-stream.v1')
          ..headers.set('x-larenor-trace-id', trace)
          ..headers.set('x-larenor-blob-content-length', mode == 'oversize' ? 262145 : payload.length)
          ..headers.set('x-larenor-blob-sha256', mode == 'digest' ? 'f' * 64 : sha256.convert(payload).toString())
          ..headers.set('x-larenor-blob-content-type', 'application/octet-stream')
          ..headers.set('x-larenor-service-revision', 4)
          ..headers.set('accept-ranges', 'none')
          ..contentLength = data.length
          ..add(data);
        await request.response.close();
      });
      addTearDown(() => fixture.server.close(force: true));
      final api = CoreBoundedDownloadApi(endpoint: fixture.endpoint);
      addTearDown(api.close);
      await expectLater(
        api.download(
          token: 'synthetic-token',
          target: target(),
          expectedUserRevision: 7,
          expectedServiceRevision: 4,
        ),
        throwsA(
          isA<CoreBoundedDownloadException>().having(
            (error) => error.code,
            'code',
            mode == 'late' ? 'late_frame' : 'invalid_response',
          ),
        ),
      );
    });
  }

  test('close cancels an in-flight request and never retries it', () async {
    var requests = 0;
    final fixture = await loopback((request) async {
      requests++;
      await Future<void>.delayed(const Duration(seconds: 2));
      await request.response.close();
    });
    addTearDown(() => fixture.server.close(force: true));
    final api = CoreBoundedDownloadApi(
      endpoint: fixture.endpoint,
      timeout: const Duration(seconds: 5),
    );
    final future = api.download(
      token: 'synthetic-token',
      target: target(),
      expectedUserRevision: 7,
      expectedServiceRevision: 4,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    api.close();
    await expectLater(
      future,
      throwsA(
        isA<CoreBoundedDownloadException>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
    expect(requests, 1);
  });
}
