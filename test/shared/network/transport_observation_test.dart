import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/shared/network/server_bound_client.dart';
import 'package:larenor/shared/network/transport_observation.dart';

void main() {
  test(
    'observer sees headers then body completion without request values',
    () async {
      final events = <TransportObservation>[];
      final chunks = StreamController<List<int>>();
      final client = ServerBoundClient(
        baseUrl: 'http://server.test',
        observer: events.add,
        inner: MockClient.streaming(
          (request, _) async => http.StreamedResponse(chunks.stream, 200),
        ),
      );
      addTearDown(client.close);
      final response = await client.send(
        http.Request('GET', Uri.parse('http://server.test/api?secret=fixture')),
      );
      expect(events.map((event) => event.kind), [
        TransportObservationKind.response,
      ]);
      final body = response.stream.toBytes();
      chunks.add([1, 2]);
      await chunks.close();
      expect(await body, [1, 2]);
      expect(events.map((event) => event.kind), [
        TransportObservationKind.response,
        TransportObservationKind.completed,
      ]);
      expect(events.every((event) => event.isRead), isTrue);
      expect(events.toString(), isNot(contains('secret')));
      expect(events.toString(), isNot(contains('server.test')));
    },
  );

  test(
    'body failure is not reported as completed and errors remain safe',
    () async {
      final events = <TransportObservation>[];
      final client = ServerBoundClient(
        baseUrl: 'http://server.test',
        observer: events.add,
        inner: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.error(http.ClientException('secret=fixture')),
            200,
          ),
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.get(Uri.parse('http://server.test/api')),
        throwsA(
          isA<http.ClientException>().having(
            (error) => error.message,
            'safe message',
            isNot(contains('fixture')),
          ),
        ),
      );
      expect(events.map((event) => event.kind), [
        TransportObservationKind.response,
        TransportObservationKind.failed,
      ]);
    },
  );

  test('write success and 403 are metadata, not domain read success', () async {
    final events = <TransportObservation>[];
    final client = ServerBoundClient(
      baseUrl: 'http://server.test',
      observer: events.add,
      inner: MockClient((_) async => http.Response('', 403)),
    );
    addTearDown(client.close);
    expect(
      (await client.post(Uri.parse('http://server.test/api'))).statusCode,
      403,
    );
    expect(
      events.every((event) => !event.isRead && event.statusCode == 403),
      isTrue,
    );
  });

  test('broken monitoring cannot break request and rejected destinations never report contact', () async {
    var calls = 0;
    final client = ServerBoundClient(
      baseUrl: 'http://server.test',
      observer: (_) => throw StateError('observer failed'),
      inner: MockClient((_) async {
        calls++;
        return http.Response('ok', 200);
      }),
    );
    addTearDown(client.close);
    expect((await client.get(Uri.parse('http://server.test/api'))).body, 'ok');
    await expectLater(
      client.get(Uri.parse('http://other.test/api')),
      throwsA(isA<http.ClientException>()),
    );
    expect(calls, 1);
  });
}
