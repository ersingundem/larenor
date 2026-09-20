import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_api.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'home_resources_fixture.dart';

Uint8List frame(
  String trace,
  int sequence,
  bool finalFrame,
  List<int> payload,
) {
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

final class _InterruptedThenResumeClient extends http.BaseClient {
  _InterruptedThenResumeClient({this.invalid});

  final String? invalid;
  final bodies = <Map<String, Object?>>[];
  int posts = 0;

  static const oldId = 'a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0';
  static const newId = 'b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0';
  static final payload = Uint8List.fromList(utf8.encode('abcdefghi'));
  static final prefix = Uint8List.fromList(utf8.encode('abc'));
  static final suffix = Uint8List.fromList(utf8.encode('defghi'));

  Map<String, String> _headers({
    required String trace,
    required int framedLength,
    required int resumeOffset,
    required bool resumed,
  }) => {
    'content-type': CoreBoundedDownloadApi.wireType,
    'content-length': '$framedLength',
    'x-larenor-trace-id': trace,
    'x-larenor-blob-content-length':
        '${resumed && invalid == 'length' ? payload.length - 1 : payload.length}',
    'x-larenor-blob-sha256': resumed && invalid == 'digest'
        ? 'f' * 64
        : sha256.convert(payload).toString(),
    'x-larenor-blob-content-type': resumed && invalid == 'mime'
        ? 'application/octet-stream'
        : 'text/plain; charset=utf-8',
    'x-larenor-service-revision': '4',
    'x-larenor-resume-offset':
        '${resumed && invalid == 'offset' ? resumeOffset + 1 : resumeOffset}',
    'accept-ranges': 'none',
  };

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request.method, 'POST');
    bodies.add(
      Map<String, Object?>.from(
        jsonDecode(await request.finalize().bytesToString()) as Map,
      ),
    );
    posts++;
    if (posts == 1) {
      final fullWire = Uint8List.fromList([
        ...frame(oldId, 0, false, prefix),
        ...frame(oldId, 1, false, suffix),
        ...frame(oldId, 2, true, const []),
      ]);
      final stream = Stream<List<int>>.multi((events) {
        events.add(frame(oldId, 0, false, prefix));
        events.add(frame(oldId, 1, false, suffix).sublist(0, 51));
        events.addError(const SocketException('synthetic interruption'));
        events.close();
      });
      return http.StreamedResponse(
        stream,
        200,
        contentLength: fullWire.length,
        headers: _headers(
          trace: oldId,
          framedLength: fullWire.length,
          resumeOffset: 0,
          resumed: false,
        ),
      );
    }
    final responseTrace = invalid == 'trace' ? 'c' * 32 : newId;
    final wire = Uint8List.fromList([
      ...frame(responseTrace, 0, false, suffix),
      ...frame(responseTrace, 1, true, const []),
    ]);
    return http.StreamedResponse(
      Stream.value(wire),
      200,
      contentLength: wire.length,
      headers: _headers(
        trace: responseTrace,
        framedLength: wire.length,
        resumeOffset: prefix.length,
        resumed: true,
      ),
    );
  }

  @override
  void close() {}
}

void main() {
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = null);
  test(
    'real loopback HTTP validates exact metadata and framed UTF-8 payload',
    () async {
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
        expect(
          request.headers.value('authorization'),
          'Bearer synthetic-token',
        );
        expect(request.headers.value('range'), isNull);
        expect(request.headers.value('if-range'), isNull);
        expect(jsonDecode(await utf8.decoder.bind(request).join()), {
          'requestId': trace,
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
          ..headers.set(
            'x-larenor-blob-sha256',
            sha256.convert(payload).toString(),
          )
          ..headers.set(
            'x-larenor-blob-content-type',
            'text/plain; charset=utf-8',
          )
          ..headers.set('x-larenor-service-revision', 4)
          ..headers.set('x-larenor-resume-offset', 0)
          ..headers.set('accept-ranges', 'none')
          ..contentLength = wire.length
          ..add(wire);
        await request.response.close();
      });
      addTearDown(() => fixture.server.close(force: true));
      final api = CoreBoundedDownloadApi(
        endpoint: fixture.endpoint,
        client: http.Client(),
        timeout: const Duration(seconds: 5),
        requestId: () => trace,
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
    },
  );

  test(
    'interrupted stream keeps complete frames and resumes with a new request',
    () async {
      final client = _InterruptedThenResumeClient();
      final ids = <String>[
        _InterruptedThenResumeClient.oldId,
        _InterruptedThenResumeClient.newId,
      ].iterator;
      final api = CoreBoundedDownloadApi(
        endpoint: ServerEndpoint('https://core.example'),
        client: client,
        requestId: () {
          ids.moveNext();
          return ids.current;
        },
      );
      addTearDown(api.close);

      CoreBoundedInterruptedDownload? interrupted;
      try {
        await api.download(
          token: 'synthetic-token',
          target: target(),
          expectedUserRevision: 7,
          expectedServiceRevision: 4,
        );
        fail('The synthetic stream must be interrupted.');
      } on CoreBoundedDownloadException catch (error) {
        expect(error.code, 'connection_failed');
        interrupted = error.interrupted;
      }
      expect(interrupted, isNotNull);
      expect(
        interrupted!.previousRequestId,
        _InterruptedThenResumeClient.oldId,
      );
      expect(interrupted.verifiedPrefix, _InterruptedThenResumeClient.prefix);
      expect(interrupted.nextOffset, 3);
      expect(interrupted.toString(), 'CoreBoundedInterruptedDownload');
      expect(interrupted.toString(), isNot(contains('core.example')));

      final result = await api.download(
        token: 'synthetic-token',
        target: target(),
        expectedUserRevision: 7,
        expectedServiceRevision: 4,
        resume: interrupted,
      );

      expect(result.bytes, _InterruptedThenResumeClient.payload);
      expect(result.requestId, _InterruptedThenResumeClient.newId);
      expect(client.bodies, [
        {
          'requestId': _InterruptedThenResumeClient.oldId,
          'expectedUserRevision': 7,
          'expectedRevision': 1,
          'expectedAclRevision': 2,
          'expectedServiceRevision': 4,
          'deadlineMs': 8000,
        },
        {
          'requestId': _InterruptedThenResumeClient.newId,
          'expectedUserRevision': 7,
          'expectedRevision': 1,
          'expectedAclRevision': 2,
          'expectedServiceRevision': 4,
          'deadlineMs': 8000,
          'resumeRequestId': _InterruptedThenResumeClient.oldId,
          'resumeOffset': 3,
        },
      ]);
    },
  );

  for (final invalid in ['offset', 'trace', 'digest', 'mime', 'length']) {
    test(
      'resume rejects changed $invalid metadata before exposing bytes',
      () async {
        final client = _InterruptedThenResumeClient(invalid: invalid);
        final ids = <String>[
          _InterruptedThenResumeClient.oldId,
          _InterruptedThenResumeClient.newId,
        ].iterator;
        final api = CoreBoundedDownloadApi(
          endpoint: ServerEndpoint('https://core.example'),
          client: client,
          requestId: () {
            ids.moveNext();
            return ids.current;
          },
        );
        addTearDown(api.close);
        CoreBoundedInterruptedDownload? interrupted;
        try {
          await api.download(
            token: 'synthetic-token',
            target: target(),
            expectedUserRevision: 7,
            expectedServiceRevision: 4,
          );
        } on CoreBoundedDownloadException catch (error) {
          interrupted = error.interrupted;
        }
        expect(interrupted, isNotNull);

        await expectLater(
          api.download(
            token: 'synthetic-token',
            target: target(),
            expectedUserRevision: 7,
            expectedServiceRevision: 4,
            resume: interrupted,
          ),
          throwsA(
            isA<CoreBoundedDownloadException>().having(
              (error) => error.code,
              'code',
              'invalid_response',
            ),
          ),
        );
      },
    );
  }

  test(
    'cancel replay is bodyless and returns the same interrupted receipt',
    () async {
      const requestId = _InterruptedThenResumeClient.oldId;
      var deletes = 0;
      final api = CoreBoundedDownloadApi(
        endpoint: ServerEndpoint('https://core.example'),
        client: MockClient((request) async {
          deletes++;
          expect(request.method, 'DELETE');
          expect(request.url.query, isEmpty);
          expect(request.bodyBytes, isEmpty);
          return http.Response(
            jsonEncode({
              'receipt': {
                'requestId': requestId,
                'traceId': requestId,
                'state': 'interrupted',
                'contentLength': 9,
                'sha256': sha256.convert(utf8.encode('abcdefghi')).toString(),
                'contentType': 'text/plain; charset=utf-8',
                'serviceRevision': 4,
                'createdAt': 10.0,
                'updatedAt': 11.0,
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(api.close);

      final first = await api.cancel(
        token: 'synthetic-token',
        target: target(),
        requestId: requestId,
      );
      final replay = await api.cancel(
        token: 'synthetic-token',
        target: target(),
        requestId: requestId,
      );

      expect(deletes, 2);
      expect(first.sameEvidence(replay), isTrue);
      expect(replay.state, CoreBoundedTransferState.interrupted);
    },
  );

  test('completed durable receipt authenticates downloaded bytes', () async {
    final payload = utf8.encode('receipt fixture');
    final trace = '4' * 32;
    final digest = sha256.convert(payload).toString();
    final wire = Uint8List.fromList([
      ...frame(trace, 0, false, payload),
      ...frame(trace, 1, true, const []),
    ]);
    final receipt = {
      'requestId': trace,
      'traceId': trace,
      'state': 'completed',
      'contentLength': payload.length,
      'sha256': digest,
      'contentType': 'application/octet-stream',
      'serviceRevision': 4,
      'createdAt': 10.0,
      'updatedAt': 11.0,
    };
    final requests = <String>[];
    final fixture = await loopback((request) async {
      requests.add(
        '${request.method} ${request.uri.path}?${request.uri.query}',
      );
      if (request.method == 'POST') {
        await request.drain<void>();
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType(
            'application',
            'vnd.larenor.blob-stream.v1',
          )
          ..headers.set('x-larenor-trace-id', trace)
          ..headers.set('x-larenor-blob-content-length', payload.length)
          ..headers.set('x-larenor-blob-sha256', digest)
          ..headers.set(
            'x-larenor-blob-content-type',
            'application/octet-stream',
          )
          ..headers.set('x-larenor-service-revision', 4)
          ..headers.set('x-larenor-resume-offset', 0)
          ..headers.set('accept-ranges', 'none')
          ..contentLength = wire.length
          ..add(wire);
      } else {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(
              request.uri.path.endsWith(trace)
                  ? {'receipt': receipt}
                  : {
                      'receipts': [receipt],
                    },
            ),
          );
      }
      await request.response.close();
    });
    addTearDown(() => fixture.server.close(force: true));
    final api = CoreBoundedDownloadApi(
      endpoint: fixture.endpoint,
      timeout: const Duration(seconds: 5),
      requestId: () => trace,
    );
    addTearDown(api.close);

    final blob = await api.download(
      token: 'synthetic-token',
      target: target(),
      expectedUserRevision: 7,
      expectedServiceRevision: 4,
    );
    final verified = await api.verifyCompleted(
      token: 'synthetic-token',
      target: target(),
      blob: blob,
    );

    expect(verified.requestId, trace);
    expect(verified.state, CoreBoundedTransferState.completed);
    expect(requests, [startsWith('POST '), endsWith('/transfers/$trace?')]);
  });

  for (final entry in {
    401: 'unauthorized',
    403: 'forbidden',
    409: 'revision_conflict',
    408: 'timeout',
  }.entries) {
    test(
      'HTTP ${entry.key} stays distinct and response secrets are discarded',
      () async {
        final fixture = await loopback((request) async {
          request.response
            ..statusCode = entry.key
            ..headers.contentType = ContentType.json
            ..write(
              '{"error":{"code":"private-secret","message":"private-secret"}}',
            );
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
                .having(
                  (error) => error.toString(),
                  'safe',
                  isNot(contains('private')),
                ),
          ),
        );
      },
    );
  }

  for (final mode in [
    'sequence',
    'late',
    'digest',
    'truncated',
    'oversize',
    'trace',
  ]) {
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
          ..headers.contentType = ContentType(
            'application',
            'vnd.larenor.blob-stream.v1',
          )
          ..headers.set('x-larenor-trace-id', trace)
          ..headers.set(
            'x-larenor-blob-content-length',
            mode == 'oversize' ? 262145 : payload.length,
          )
          ..headers.set(
            'x-larenor-blob-sha256',
            mode == 'digest' ? 'f' * 64 : sha256.convert(payload).toString(),
          )
          ..headers.set(
            'x-larenor-blob-content-type',
            'application/octet-stream',
          )
          ..headers.set('x-larenor-service-revision', 4)
          ..headers.set('x-larenor-resume-offset', 0)
          ..headers.set('accept-ranges', 'none')
          ..contentLength = data.length
          ..add(data);
        await request.response.close();
      });
      addTearDown(() => fixture.server.close(force: true));
      final api = CoreBoundedDownloadApi(
        endpoint: fixture.endpoint,
        requestId: () => mode == 'trace' ? '3' * 32 : trace,
      );
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

  test('client deadline aborts a stalled request without retrying', () async {
    var requests = 0;
    final fixture = await loopback((request) async {
      requests++;
      await Future<void>.delayed(const Duration(seconds: 2));
      await request.response.close();
    });
    addTearDown(() => fixture.server.close(force: true));
    final api = CoreBoundedDownloadApi(
      endpoint: fixture.endpoint,
      timeout: const Duration(milliseconds: 40),
    );
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
          'timeout',
        ),
      ),
    );
    expect(requests, 1);
  });

  test('reads bounded transfer history with exact resource authority', () async {
    final receiptId = '4' * 32;
    final traceId = receiptId;
    final fixture = await loopback((request) async {
      expect(request.method, 'GET');
      expect(
        request.uri.path,
        '/api/v1/home-resources/${'a' * 32}/${'b' * 32}/${'3' * 32}/blob/transfers',
      );
      expect(request.uri.queryParameters, {'limit': '20'});
      expect(request.headers.value('authorization'), 'Bearer synthetic-token');
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'receipts': [
              {
                'requestId': receiptId,
                'traceId': traceId,
                'state': 'completed',
                'contentLength': 42,
                'sha256': '6' * 64,
                'contentType': 'application/pdf',
                'serviceRevision': 7,
                'createdAt': 1789911000.25,
                'updatedAt': 1789911001.5,
              },
            ],
          }),
        );
      await request.response.close();
    });
    addTearDown(() => fixture.server.close(force: true));
    final api = CoreBoundedDownloadApi(endpoint: fixture.endpoint);
    addTearDown(api.close);

    final history = await api.history(
      token: 'synthetic-token',
      target: target(),
      limit: 20,
    );

    expect(history, hasLength(1));
    expect(history.single.requestId, receiptId);
    expect(history.single.traceId, traceId);
    expect(history.single.state, CoreBoundedTransferState.completed);
    expect(history.single.contentLength, 42);
    expect(history.single.contentType, 'application/pdf');
    expect(history.single.serviceRevision, 7);
    expect(
      history.single.createdAt,
      DateTime.fromMillisecondsSinceEpoch(1789911000250),
    );
    expect(
      history.single.updatedAt,
      DateTime.fromMillisecondsSinceEpoch(1789911001500),
    );
    expect(history.single.toString(), 'CoreBoundedTransferReceipt');
  });

  test(
    'transfer history rejects malformed or excessive receipt lists',
    () async {
      for (final body in <Object?>[
        {'receipts': List.filled(51, const <String, Object?>{})},
        {
          'receipts': [
            {
              'requestId': '4' * 32,
              'traceId': '5' * 32,
              'state': 'completed',
              'contentLength': 42,
              'sha256': '6' * 64,
              'contentType': 'application/pdf',
              'serviceRevision': 7,
              'createdAt': 1789911000.25,
              'updatedAt': 1789911001.5,
            },
          ],
        },
        {
          'receipts': [
            {
              'requestId': '4' * 32,
              'traceId': '5' * 32,
              'state': 'completed',
              'contentLength': 42,
              'sha256': '6' * 64,
              'contentType': 'application/pdf',
              'serviceRevision': 7,
              'createdAt': 1789911001.5,
              'updatedAt': 1789911000.25,
            },
          ],
        },
      ]) {
        final fixture = await loopback((request) async {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(body));
          await request.response.close();
        });
        final api = CoreBoundedDownloadApi(endpoint: fixture.endpoint);
        await expectLater(
          api.history(token: 'synthetic-token', target: target()),
          throwsA(
            isA<CoreBoundedDownloadException>().having(
              (error) => error.code,
              'code',
              'invalid_response',
            ),
          ),
        );
        api.close();
        await fixture.server.close(force: true);
      }
    },
  );

  test(
    'accepts creation ordering when an older transfer finishes later',
    () async {
      Map<String, Object?> receipt(String id, double created, double updated) =>
          {
            'requestId': id * 32,
            'traceId': id * 32,
            'state': 'completed',
            'contentLength': 1,
            'sha256': id * 64,
            'contentType': 'application/octet-stream',
            'serviceRevision': 1,
            'createdAt': created,
            'updatedAt': updated,
          };
      final fixture = await loopback((request) async {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'receipts': [receipt('8', 2000, 2001), receipt('7', 1000, 3000)],
            }),
          );
        await request.response.close();
      });
      addTearDown(() => fixture.server.close(force: true));
      final api = CoreBoundedDownloadApi(endpoint: fixture.endpoint);
      addTearDown(api.close);

      final result = await api.history(
        token: 'synthetic-token',
        target: target(),
      );

      expect(result.map((receipt) => receipt.requestId), ['8' * 32, '7' * 32]);
    },
  );
}
