import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
// The pinned plugin's real platform channel is the effect boundary.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/features/media/arr/providers/sonarr_providers.dart';
import 'package:larenor/features/media/arr/providers/radarr_providers.dart';
import 'package:larenor/features/media/arr/providers/lidarr_providers.dart';
import 'package:larenor/features/media/arr/providers/readarr_providers.dart';
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';
import 'package:larenor/features/media/bazarr/providers/bazarr_providers.dart';
import 'package:larenor/features/media/prowlarr/providers/prowlarr_providers.dart';

import 'direct_arr_actions_test.dart' show arrSignIn, arrSignOut;
import 'direct_arr_credentials_test.dart';
import 'direct_api_key_actions_test.dart'
    show apiKeySignIn, apiKeySignOut, ClosingHttp;
import 'direct_api_key_credentials_test.dart';
import 'direct_home_routines_test.dart' show routinesHome;

ProviderListenable<Object?> reader(String name) => switch (name) {
  'sonarr' => sonarrClientProvider,
  'radarr' => radarrClientProvider,
  'lidarr' => lidarrClientProvider,
  'readarr' => readarrClientProvider,
  'jellyseerr' => jellyseerrClientProvider,
  'bazarr' => bazarrClientProvider,
  _ => prowlarrClientProvider,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ApiKeyPlatform secure;
  late FlutterSecureStoragePlatform previous;
  setUp(() {
    secure = ApiKeyPlatform();
    for (final name in arrServices) {
      secure.values['${name}_base_url'] = 'https://old.invalid';
      secure.values['${name}_api_key'] = 'synthetic-old-key';
    }
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          secure.handle,
        );
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });
  for (final name in [...arrServices, ...apiKeyServices]) {
    final arr = arrServices.contains(name);
    for (final signOut in [false, true]) {
      for (final failedAt in [0, 1, 2, 3]) {
        test(
          '$name ${signOut ? "clear" : "save"} uncertain effect$failedAt retires confirmed reader',
          () async {
            var closed = 0, requests = 0;
            await http.runWithClient(
              () async {
                final (c, _) = await routinesHome('direct');
                final connection = arr ? holdArr(c, name) : holdApiKey(c, name);
                addTearDown(connection.close);
                await (arr
                    ? arrConnection(c, name)
                    : apiKeyConnection(c, name));
                final sub = c.listen(reader(name), (_, _) {});
                addTearDown(sub.close);
                expect(sub.read(), isNotNull);
                secure.calls.clear();
                secure.failAt = failedAt;
                secure.failAfter = failedAt == 3;
                final operation = signOut
                    ? (arr ? arrSignOut(c, name)() : apiKeySignOut(c, name)())
                    : (arr
                          ? arrSignIn(c, name)(
                              baseUrl: 'https://new.invalid',
                              apiKey: 'new',
                            )
                          : apiKeySignIn(c, name)(
                              baseUrl: 'https://new.invalid',
                              apiKey: 'new',
                            ));
                await expectLater(
                  operation,
                  throwsA(isA<DirectHomeAccessException>()),
                );
                await c.pump();
                expect(
                  (connection.read() as AsyncValue<Object?>).hasError,
                  isTrue,
                );
                expect(sub.read(), isNull);
                expect(closed, greaterThanOrEqualTo(1));
                expect(requests, signOut ? 0 : 1);
                // No cleanup or retry after an ambiguous platform result.
                expect(secure.calls.length, failedAt + 1);
                expect(
                  secure.values.containsKey('${name}_connection_pending_v1'),
                  failedAt != 0 && failedAt != 3,
                );
              },
              () => ClosingHttp((_) async {
                requests++;
                return http.Response('{}', 200);
              }, () => closed++),
            );
          },
        );
      }
    }
    test(
      '$name rejected authentication retains its unchanged confirmed reader',
      () async {
        await http.runWithClient(() async {
          final (c, _) = await routinesHome('direct');
          final connection = arr ? holdArr(c, name) : holdApiKey(c, name);
          addTearDown(connection.close);
          await (arr ? arrConnection(c, name) : apiKeyConnection(c, name));
          final sub = c.listen(reader(name), (_, _) {});
          addTearDown(sub.close);
          final original = sub.read();
          expect(original, isNotNull);
          secure.calls.clear();
          await expectLater(
            arr
                ? arrSignIn(c, name)(
                    baseUrl: 'https://new.invalid',
                    apiKey: 'new',
                  )
                : apiKeySignIn(c, name)(
                    baseUrl: 'https://new.invalid',
                    apiKey: 'new',
                  ),
            throwsA(isA<Exception>()),
          );
          await c.pump();
          expect((connection.read() as AsyncValue<Object?>).hasError, isFalse);
          expect(sub.read(), same(original));
          expect(secure.calls, isEmpty);
        }, () => ClosingHttp((_) async => http.Response('{}', 401), () {}));
      },
    );
  }
}
