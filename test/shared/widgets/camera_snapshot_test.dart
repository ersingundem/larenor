import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/shared/widgets/camera_snapshot.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

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
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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
    expect(find.byType(RawImage), findsNothing);
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

  testWidgets('hidden camera tabs do not poll and refresh on return', (
    tester,
  ) async {
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
    Widget app(bool visible) => ProviderScope(
      overrides: [haRestClientProvider.overrideWithValue(client)],
      child: CupertinoApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: TickerMode(
          enabled: visible,
          child: const CameraSnapshot(
            entityId: 'camera.front',
            refreshInterval: Duration(seconds: 1),
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(false));
    await tester.pump(const Duration(seconds: 10));
    expect(calls, 0);
    await tester.pumpWidget(app(true));
    await tester.pump();
    expect(calls, 1);
    expect(find.text('Camera image could not be refreshed'), findsOneWidget);
    await tester.pumpWidget(app(false));
    await tester.pump(const Duration(seconds: 10));
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'invalid 200 refresh retains timestamped last frame and marks it stale',
    (tester) async {
      var fail = false;
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=',
      );
      final client = HaRestClient(
        baseUrl: 'http://camera.test',
        token: 'example',
        httpClient: MockClient(
          (_) async =>
              fail ? http.Response('', 200) : http.Response.bytes(png, 200),
        ),
      );
      addTearDown(client.dispose);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [haRestClientProvider.overrideWithValue(client)],
            child: CupertinoApp(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const CameraSnapshot(
                entityId: 'camera.front',
                refreshInterval: Duration(seconds: 1),
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(find.byType(RawImage), findsOneWidget);
      final image = tester.widget<RawImage>(find.byType(RawImage)).image;
      final caption = tester
          .widget<Text>(find.textContaining('Snapshot received ·'))
          .data!;
      fail = true;
      // Lifecycle refresh works in real time even though the first decode ran
      // outside FakeAsync to allow the engine codec to complete.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(image));
      expect(
        find.textContaining('Camera image could not be refreshed'),
        findsOneWidget,
      );
      expect(find.textContaining(caption), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

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
          child: CupertinoApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
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
