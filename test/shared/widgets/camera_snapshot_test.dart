import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/shared/widgets/camera_snapshot.dart';

void main() {
  testWidgets('camera ignores stale entity frames and serializes refreshes', (
    tester,
  ) async {
    final pending = <Completer<http.Response>>[];
    final paths = <String>[];
    final client = HaRestClient(
      baseUrl: 'http://camera.test',
      token: 'example',
      httpClient: MockClient((request) {
        paths.add(request.url.path);
        final completer = Completer<http.Response>();
        pending.add(completer);
        return completer.future;
      }),
    );
    addTearDown(client.dispose);
    Widget app(String entityId) => ProviderScope(
      overrides: [haRestClientProvider.overrideWithValue(client)],
      child: CupertinoApp(
        home: CameraSnapshot(
          entityId: entityId,
          refreshInterval: const Duration(seconds: 1),
        ),
      ),
    );
    await tester.pumpWidget(app('camera.old'));
    await tester.pump(const Duration(seconds: 5));
    expect(paths, ['/api/camera_proxy/camera.old']);
    await tester.pumpWidget(app('camera.new'));
    pending.first.complete(http.Response.bytes([1, 2, 3], 200));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(paths, [
      '/api/camera_proxy/camera.old',
      '/api/camera_proxy/camera.new',
    ]);
    await tester.pumpWidget(const SizedBox());
    pending.last.complete(http.Response.bytes([4, 5, 6], 200));
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
    expect(paths, hasLength(2));
  });

  testWidgets(
    'camera pauses background requests and survives disconnected HA',
    (tester) async {
      var calls = 0;
      final client = HaRestClient(
        baseUrl: 'http://camera.test',
        token: 'example',
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('', 503);
        }),
      );
      addTearDown(client.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [haRestClientProvider.overrideWithValue(client)],
          child: const CupertinoApp(
            home: CameraSnapshot(
              entityId: 'camera.front',
              refreshInterval: Duration(seconds: 1),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(calls, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 1));
      expect(calls, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
