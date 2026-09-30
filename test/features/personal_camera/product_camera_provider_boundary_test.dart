import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';

void main() {
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = null);

  test('owned HA TCP camera snapshot boundary is authenticated', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <HttpRequest>[];
    final received = Completer<void>();
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=',
    );
    final serving = server.listen((request) async {
      requests.add(request);
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('image', 'png')
        ..add(png);
      await request.response.close();
      if (!received.isCompleted) received.complete();
    });
    addTearDown(serving.cancel);
    final client = HaRestClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      token: 'fixture-camera-token',
    );
    addTearDown(client.dispose);

    final bytes = await client
        .getCameraImage('camera.front_door')
        .timeout(const Duration(seconds: 3));
    await received.future.timeout(const Duration(seconds: 3));

    expect(bytes, png);
    expect(requests.single.uri.path, '/api/camera_proxy/camera.front_door');
    expect(
      requests.single.headers.value(HttpHeaders.authorizationHeader),
      'Bearer fixture-camera-token',
    );
    expect(requests.single.method, 'GET');
  });
}
