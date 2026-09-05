import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:larenor/shared/network/server_bound_client.dart';

// This single integration fixture deliberately exercises real loopback sockets.
// Widget-suite initialization otherwise replaces HttpClient with HTTP 400 mocks.
class _LoopbackTransport extends HttpOverrides {}

void main() {
  group('authenticated server boundary', () {
    for (final url in [
      'file:///tmp/server',
      'https://example.test:70000',
      'https://user:password@example.test',
      'https://example.test?api_key=private',
      'https://example.test#private',
      'https://example.test\\@another.test',
    ]) {
      test('rejects invalid connection URLs without echoing them: $url', () {
        expect(
          () => ServerBoundClient(baseUrl: url),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'Invalid server URL.',
            ),
          ),
        );
      });
    }

    test('supports local HTTP and reverse proxy paths', () async {
      final client = ServerBoundClient(
        baseUrl: 'http://192.0.2.1:8123/media/',
        inner: MockClient((request) async {
          expect(request.url.path, '/media/api/status');
          expect(request.followRedirects, isFalse);
          expect(request.headers['X-Api-Key'], 'private');
          return http.Response('ok', 200);
        }),
      );
      addTearDown(client.close);
      expect(
        (await client.get(
          Uri.parse('http://192.0.2.1:8123/media/api/status'),
          headers: {'X-Api-Key': 'private'},
        )).body,
        'ok',
      );
    });

    for (final destination in [
      'https://another.test/media/api',
      'http://example.test/media/api',
      'https://example.test:8443/media/api',
      'https://example.test/another/api',
      'https://example.test/media-other/api',
      'https://example.test/media/../another/api',
      'https://example.test/media/%2e%2e/another/api',
      'https://example.test/media/%252e%252e/another/api',
      'https://example.test/media/%2f..%2fanother/api',
      'https://example.test/media/%252f..%252fanother/api',
      'https://example.test/media/%5c..%5canother/api',
      'https://example.test/media/%255c..%255canother/api',
      'https://private@example.test/media/api',
    ]) {
      test('blocks destination before sending: $destination', () async {
        final client = ServerBoundClient(
          baseUrl: 'https://example.test/media',
          inner: MockClient(
            (request) async => fail('Must not send credentials.'),
          ),
        );
        addTearDown(client.close);
        await expectLater(
          client.get(Uri.parse(destination)),
          throwsA(isA<http.ClientException>()),
        );
      });
    }

    test(
      'does not forward API keys or cookies across a real redirect',
      () async {
        final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await source.close(force: true);
          await target.close(force: true);
        });
        var leakedRequests = 0;
        target.listen((request) {
          leakedRequests++;
          request.response.statusCode = 200;
          request.response.close();
        });
        source.listen((request) {
          expect(request.headers.value('X-Api-Key'), 'private-key');
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            'http://127.0.0.1:${target.port}/capture?api_key=private-key',
          );
          request.response.close();
        });
        final client = ServerBoundClient(
          baseUrl: 'http://127.0.0.1:${source.port}',
          inner: IOClient(_LoopbackTransport().createHttpClient(null)),
        );
        addTearDown(client.close);
        await expectLater(
          client.get(
            Uri.parse('http://127.0.0.1:${source.port}/status'),
            headers: {
              'X-Api-Key': 'private-key',
              'Cookie': 'session=private-cookie',
            },
          ),
          throwsA(
            isA<http.ClientException>().having(
              (error) => error.toString(),
              'safe message',
              allOf(contains('redirected'), isNot(contains('private-key'))),
            ),
          ),
        );
        expect(leakedRequests, 0);
      },
    );

    test('transport failures do not expose credential-bearing URLs', () async {
      final client = ServerBoundClient(
        baseUrl: 'https://example.test',
        inner: MockClient((request) async {
          throw http.ClientException('api_key=private-secret', request.url);
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.get(Uri.parse('https://example.test/?api_key=private-secret')),
        throwsA(
          isA<http.ClientException>().having(
            (error) => error.toString(),
            'safe error',
            isNot(contains('private-secret')),
          ),
        ),
      );
    });
  });

  test(
    'server messages redact raw and encoded credentials and bound length',
    () {
      final safe = redactServerMessage(
        'secret/value secret%2Fvalue ${'x' * 1200}',
        ['secret/value', '', null],
      );
      expect(safe, startsWith('[redacted] [redacted]'));
      expect(safe, isNot(contains('secret')));
      expect(safe.length, 1001);
    },
  );
  test('malformed JSON does not expose its source in error messages', () {
    expect(
      () => decodeServerJson('{"AccessToken":"private-token"'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.toString(),
          'safe error',
          isNot(contains('private-token')),
        ),
      ),
    );
  });
  test('response stream failures also mask credential-bearing URLs', () async {
    final client = ServerBoundClient(
      baseUrl: 'https://example.test',
      inner: MockClient.streaming(
        (request, body) async => http.StreamedResponse(
          Stream.error(
            http.ClientException('private-stream-token', request.url),
          ),
          200,
        ),
      ),
    );
    addTearDown(client.close);
    await expectLater(
      client.get(
        Uri.parse('https://example.test/?api_key=private-stream-token'),
      ),
      throwsA(
        isA<http.ClientException>().having(
          (error) => error.toString(),
          'safe error',
          isNot(contains('private-stream-token')),
        ),
      ),
    );
  });
  test(
    'rejects header injection without exposing the invalid secret',
    () async {
      final client = ServerBoundClient(
        baseUrl: 'https://example.test',
        inner: MockClient(
          (request) async => fail('Invalid headers must not be sent.'),
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.get(
          Uri.parse('https://example.test/status'),
          headers: {'X-Api-Key': 'private-key\r\nInjected: yes'},
        ),
        throwsA(
          isA<http.ClientException>().having(
            (error) => error.toString(),
            'safe error',
            isNot(contains('private-key')),
          ),
        ),
      );
    },
  );
}
