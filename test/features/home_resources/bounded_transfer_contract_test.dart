import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_api.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

Map<String, dynamic> _contract() =>
    jsonDecode(File('contracts/bounded-transfer.v1.json').readAsStringSync())
        as Map<String, dynamic>;

HomeResourceRecord _target(Map<String, dynamic> fixture) =>
    HomeResourceRecord.fromJson(
      fixture['target'],
      expectedContext: ServerContext.fromJson(fixture['context']),
    );

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

Future<Object?> _requestJson(HttpRequest request) async =>
    jsonDecode(await utf8.decoder.bind(request).join());

void _jsonResponse(HttpResponse response, Map<String, dynamic> contract) {
  response
    ..statusCode = contract['status'] as int
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(contract['response']));
}

void main() {
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = null);

  test('actual Core upload and descriptor contract round-trips', () async {
    final fixture = _contract();
    final upload = fixture['upload'] as Map<String, dynamic>;
    final descriptor = fixture['descriptor'] as Map<String, dynamic>;
    final payload = base64Decode(upload['payloadBase64'] as String);
    final requestHeaders = Map<String, dynamic>.from(
      upload['requestHeaders'] as Map,
    );
    var calls = 0;
    final loopback = await _loopback((request) async {
      calls++;
      expect(request.headers.value('authorization'), 'Bearer fixture-token');
      if (request.method == upload['method']) {
        expect(request.uri.path, upload['path']);
        for (final entry in requestHeaders.entries) {
          expect(request.headers.value(entry.key), entry.value);
        }
        expect(
          await request.fold<List<int>>(
            <int>[],
            (value, chunk) => value..addAll(chunk),
          ),
          payload,
        );
        _jsonResponse(request.response, upload);
      } else {
        expect(request.method, descriptor['method']);
        expect(request.uri.path, descriptor['path']);
        _jsonResponse(request.response, descriptor);
      }
      await request.response.close();
    });
    addTearDown(() => loopback.server.close(force: true));
    final uploadId = (upload['response'] as Map)['blob']['requestId'] as String;
    final api = CoreBoundedDownloadApi(
      endpoint: loopback.endpoint,
      requestId: () => uploadId,
    );
    addTearDown(api.close);
    final target = _target(fixture);

    final result = await api.upload(
      token: 'fixture-token',
      target: target,
      expectedUserRevision: fixture['userRevision'] as int,
      expectedServiceRevision: 0,
      source: CoreBoundedUploadSource(
        filename: 'contract.txt',
        contentType: requestHeaders['content-type'] as String,
        bytes: Uint8List.fromList(payload),
      ),
    );
    final current = await api.descriptor(
      token: 'fixture-token',
      target: target,
    );

    expect(result.requestId, uploadId);
    expect(result.descriptor.serviceRevision, 1);
    expect(
      result.descriptor.authenticates(result.sourceDigest, payload.length),
      isTrue,
    );
    expect(current.serviceRevision, result.descriptor.serviceRevision);
    expect(current.sha256, result.descriptor.sha256);
    expect(calls, 2);
  });

  test(
    'actual framed bytes authenticate the retained receipt and history',
    () async {
      final fixture = _contract();
      final download = fixture['download'] as Map<String, dynamic>;
      final receipt = fixture['receipt'] as Map<String, dynamic>;
      final history = fixture['history'] as Map<String, dynamic>;
      final responseHeaders = Map<String, dynamic>.from(
        download['responseHeaders'] as Map,
      );
      final wire = base64Decode(download['wireBase64'] as String);
      final calls = <String>[];
      final loopback = await _loopback((request) async {
        calls.add('${request.method} ${request.uri.path}?${request.uri.query}');
        expect(request.headers.value('authorization'), 'Bearer fixture-token');
        if (request.method == 'POST') {
          expect(request.uri.path, download['path']);
          expect(request.headers.value('range'), isNull);
          expect(request.headers.value('if-range'), isNull);
          expect(await _requestJson(request), download['request']);
          request.response.statusCode = download['status'] as int;
          for (final entry in responseHeaders.entries) {
            request.response.headers.set(entry.key, entry.value);
          }
          request.response.add(wire);
        } else if (request.uri.path == receipt['path']) {
          _jsonResponse(request.response, receipt);
        } else {
          expect('${request.uri.path}?${request.uri.query}', history['path']);
          _jsonResponse(request.response, history);
        }
        await request.response.close();
      });
      addTearDown(() => loopback.server.close(force: true));
      final requestId = (download['request'] as Map)['requestId'] as String;
      final api = CoreBoundedDownloadApi(
        endpoint: loopback.endpoint,
        requestId: () => requestId,
      );
      addTearDown(api.close);
      final target = _target(fixture);

      final blob = await api.download(
        token: 'fixture-token',
        target: target,
        expectedUserRevision: fixture['userRevision'] as int,
        expectedServiceRevision: 1,
      );
      final proof = await api.verifyCompleted(
        token: 'fixture-token',
        target: target,
        blob: blob,
      );
      final retained = await api.history(
        token: 'fixture-token',
        target: target,
        limit: 20,
      );

      expect(proof.authenticates(blob), isTrue);
      expect(retained, hasLength(1));
      expect(retained.single.requestId, proof.requestId);
      expect(calls, hasLength(3));
    },
  );

  test(
    'actual stale and range failures stay closed and content-free',
    () async {
      final fixture = _contract();
      final errors = fixture['errors'] as Map<String, dynamic>;
      final stale = errors['staleRevision'] as Map<String, dynamic>;
      final ranged = errors['range'] as Map<String, dynamic>;
      final loopback = await _loopback((request) async {
        expect(request.method, 'POST');
        expect(request.headers.value('range'), isNull);
        expect(request.headers.value('if-range'), isNull);
        expect(await _requestJson(request), stale['request']);
        _jsonResponse(request.response, stale);
        await request.response.close();
      });
      addTearDown(() => loopback.server.close(force: true));
      final staleId = (stale['request'] as Map)['requestId'] as String;
      final api = CoreBoundedDownloadApi(
        endpoint: loopback.endpoint,
        requestId: () => staleId,
      );
      addTearDown(api.close);

      await expectLater(
        api.download(
          token: 'fixture-token',
          target: _target(fixture),
          expectedUserRevision: fixture['userRevision'] as int,
          expectedServiceRevision: 2,
        ),
        throwsA(
          isA<CoreBoundedDownloadException>()
              .having((error) => error.code, 'code', 'revision_conflict')
              .having(
                (error) => error.toString(),
                'content-free',
                isNot(contains('payloadBase64')),
              ),
        ),
      );
      expect(ranged['status'], 400);
      expect((ranged['response'] as Map)['error'], {
        'code': 'invalid_request',
        'message': 'The request is invalid.',
      });
      expect((fixture['history'] as Map)['response']['receipts'], hasLength(1));
    },
  );
}
