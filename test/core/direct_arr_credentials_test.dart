import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// Use the pinned plugin's real MethodChannel boundary, never a credential store mock.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/features/media/arr/data/arr_config.dart';
import 'package:larenor/features/media/arr/data/arr_credentials_store.dart';
import 'package:larenor/features/media/arr/providers/sonarr_providers.dart';
import 'package:larenor/features/media/arr/providers/radarr_providers.dart';
import 'package:larenor/features/media/arr/providers/lidarr_providers.dart';
import 'package:larenor/features/media/arr/providers/readarr_providers.dart';

import 'direct_home_boundary_test.dart' show SecurePlatform;
import 'direct_home_routines_test.dart' show routinesHome;

const arrServices = ['sonarr', 'radarr', 'lidarr', 'readarr'];
ArrCredentialsStore arrStore(ProviderContainer c, String name) =>
    switch (name) {
      'sonarr' => c.read(sonarrCredentialsStoreProvider),
      'radarr' => c.read(radarrCredentialsStoreProvider),
      'lidarr' => c.read(lidarrCredentialsStoreProvider),
      _ => c.read(readarrCredentialsStoreProvider),
    };
Future<ArrConfig?> arrConnection(ProviderContainer c, String name) =>
    switch (name) {
      'sonarr' => c.read(sonarrConnectionProvider.future),
      'radarr' => c.read(radarrConnectionProvider.future),
      'lidarr' => c.read(lidarrConnectionProvider.future),
      _ => c.read(readarrConnectionProvider.future),
    };
ProviderSubscription<dynamic> holdArr(ProviderContainer c, String name) =>
    switch (name) {
      'sonarr' => c.listen(sonarrConnectionProvider, (_, _) {}),
      'radarr' => c.listen(radarrConnectionProvider, (_, _) {}),
      'lidarr' => c.listen(lidarrConnectionProvider, (_, _) {}),
      _ => c.listen(readarrConnectionProvider, (_, _) {}),
    };

class ArrSecurePlatform extends SecurePlatform {
  ArrSecurePlatform() {
    values.clear();
    for (final name in arrServices) {
      values['${name}_base_url'] = 'https://old.invalid';
      values['${name}_api_key'] = 'synthetic-old-key';
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ArrSecurePlatform secure;
  late FlutterSecureStoragePlatform previous;
  setUp(() {
    secure = ArrSecurePlatform();
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
  for (final name in arrServices) {
    for (final mode in ['core', 'pending', 'error']) {
      test(
        '$name $mode actual provider never reads Direct credentials',
        () async {
          final (c, _) = await routinesHome(mode);
          final sub = holdArr(c, name);
          addTearDown(sub.close);
          await expectLater(
            arrConnection(c, name),
            throwsA(isA<DirectHomeAccessException>()),
          );
          expect(secure.calls, isEmpty);
        },
      );
    }
    test('$name held Core store cannot read write or clear', () async {
      final (c, _) = await routinesHome('core');
      final store = arrStore(c, name);
      for (final operation in <Future<void> Function()>[
        () async {
          await store.read();
        },
        () => store.save(
          baseUrl: 'https://new.invalid',
          apiKey: 'synthetic-new-key',
        ),
        store.clear,
      ]) {
        await expectLater(
          Future.sync(operation),
          throwsA(isA<DirectHomeAccessException>()),
        );
      }
      expect(secure.calls, isEmpty);
    });
    test(
      '$name standalone complete tuple retains public constructor behavior',
      () async {
        final store = ArrCredentialsStore(servicePrefix: name);
        expect((await store.read())!.baseUrl, 'https://old.invalid');
        await store.save(
          baseUrl: 'https://new.invalid',
          apiKey: 'synthetic-new-key',
        );
        final saved = await store.read();
        expect(saved!.baseUrl, 'https://new.invalid');
        expect(saved.apiKey, 'synthetic-new-key');
        await store.clear();
        expect(await store.read(), isNull);
      },
    );
    test(
      '$name pending marker blocks mixed tuple before any credential read',
      () async {
        secure.values['${name}_base_url'] = 'https://new.invalid';
        secure.values['${name}_connection_pending_v1'] = '1';
        await expectLater(
          ArrCredentialsStore(servicePrefix: name).read(),
          throwsA(
            isA<DirectHomeAccessException>().having(
              (e) => e.code,
              'code',
              'pending_mutation',
            ),
          ),
        );
        expect(secure.calls, [('read', '${name}_connection_pending_v1')]);
      },
    );
  }
  test(
    'unknown Arr prefix cannot select arbitrary secure-storage keys',
    () async {
      for (final prefix in ['other', 'ha', 'sonarr/../radarr', 'Sonarr', '']) {
        await expectLater(
          Future.sync(() async {
            final store = ArrCredentialsStore(servicePrefix: prefix);
            await store.save(
              baseUrl: 'https://new.invalid',
              apiKey: 'synthetic-new-key',
            );
          }),
          throwsA(isA<ArgumentError>()),
        );
      }
      expect(secure.calls, isEmpty);
    },
  );
}
