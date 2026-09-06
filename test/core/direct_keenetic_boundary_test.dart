import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// The real public platform seam of the pinned secure storage plugin.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/core/direct_credential_record.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/keenetic/data/keenetic_credentials_store.dart';
import 'package:larenor/features/keenetic/providers/keenetic_providers.dart';
import 'package:larenor/features/keenetic/providers/keenetic_telemetry_providers.dart';

import 'direct_home_boundary_test.dart' show SecurePlatform;
import 'direct_home_routines_test.dart' show routinesHome;

const keeneticRecord = {
  'keenetic_base_url': 'https://router.invalid/prefix',
  'keenetic_username': 'synthetic-user',
  'keenetic_password': 'synthetic-password',
};

http.Response keeneticReply(http.Request request) => switch (request.url.path) {
  '/prefix/auth' || '/auth' => http.Response(
    '',
    200,
    headers: {'set-cookie': 'session=synthetic; Path=/'},
  ),
  '/prefix/rci/show/version' || '/rci/show/version' => http.Response(
    '{"model":"Synthetic router","release":"1.0"}',
    200,
  ),
  _ => http.Response('{}', 200),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecurePlatform secure;
  late FlutterSecureStoragePlatform previous;
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final marker = DirectCredentialService.keenetic.pendingMutationKey;
  setUp(() {
    secure = SecurePlatform()
      ..values.clear()
      ..values.addAll(keeneticRecord);
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    messenger.setMockMethodCallHandler(channel, secure.handle);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    FlutterSecureStoragePlatform.instance = previous;
  });

  for (final mode in ['core', 'pending', 'error']) {
    test(
      '$mode actual connection rejects before reading the Direct record',
      () async {
        final (c, _) = await routinesHome(mode);
        final sub = c.listen(keeneticConnectionProvider, (_, _) {});
        addTearDown(sub.close);
        await expectLater(
          c.read(keeneticConnectionProvider.future),
          throwsA(isA<DirectHomeAccessException>()),
        );
        expect(secure.calls, isEmpty);
      },
    );
    test('$mode held typed store cannot read save or clear', () async {
      final (c, _) = await routinesHome(mode);
      final store = c.read(keeneticCredentialsStoreProvider);
      for (final action in <Future<void> Function()>[
        () async {
          await store.read();
        },
        () => store.save(
          baseUrl: 'https://new.invalid',
          username: 'new',
          password: '',
        ),
        store.clear,
      ]) {
        await expectLater(
          Future.sync(action),
          throwsA(isA<DirectHomeAccessException>()),
        );
      }
      expect(secure.calls, isEmpty);
    });
  }

  test(
    'Core creates no normal or telemetry transport even with a saved tuple',
    () async {
      var clients = 0, requests = 0;
      await http.runWithClient(
        () async {
          final (c, _) = await routinesHome('core');
          final sub = c.listen(keeneticClientProvider, (_, _) {});
          addTearDown(sub.close);
          try {
            await c.read(keeneticClientProvider.future);
          } catch (_) {}
          final telemetry = c.listen(
            keeneticTelemetryControllerProvider,
            (_, _) {},
          );
          addTearDown(telemetry.close);
          await c.pump();
          expect(clients, 0);
          expect(requests, 0);
          expect(secure.calls, isEmpty);
        },
        () {
          clients++;
          return MockClient((request) async {
            requests++;
            return keeneticReply(request);
          });
        },
      );
    },
  );

  for (final value in ['1', '', 'false', 'synthetic-private-marker']) {
    test(
      'any pending marker length ${value.length} denies tuple acquisition',
      () async {
        secure.values[marker] = value;
        await expectLater(
          KeeneticCredentialsStore().read(),
          throwsA(
            isA<DirectHomeAccessException>().having(
              (e) => e.code,
              'code',
              'pending_mutation',
            ),
          ),
        );
        expect(secure.calls.map((c) => c.$2), [marker]);
      },
    );
  }

  test(
    'all absent is unconfigured, empty password remains a valid saved field',
    () async {
      secure.values.clear();
      expect(await KeeneticCredentialsStore().read(), isNull);
      secure.values.addAll({...keeneticRecord, 'keenetic_password': ''});
      final config = await KeeneticCredentialsStore().read();
      expect(config!.password, '');
    },
  );

  final malformed = <Map<String, String>>[
    for (final missing in keeneticRecord.keys)
      Map.of(keeneticRecord)..remove(missing),
    {
      ...keeneticRecord,
      'keenetic_base_url': 'https://user:private@router.invalid',
    },
    {
      ...keeneticRecord,
      'keenetic_base_url': 'https://router.invalid?private=yes',
    },
    {...keeneticRecord, 'keenetic_username': ''},
    {...keeneticRecord, 'keenetic_username': 'private\nuser'},
  ];
  for (var i = 0; i < malformed.length; i++) {
    test(
      'invalid saved tuple $i is typed failure, never unconfigured or exposed',
      () async {
        secure.values
          ..clear()
          ..addAll(malformed[i]);
        await expectLater(
          KeeneticCredentialsStore().read(),
          throwsA(
            isA<DirectHomeAccessException>().having(
              (e) => e.code,
              'code',
              'invalid_record',
            ),
          ),
        );
      },
    );
  }

  for (final field in keeneticRecord.keys) {
    test(
      'partial $field write keeps quarantine through restart until explicit replacement',
      () async {
        var fail = true;
        messenger.setMockMethodCallHandler(channel, (call) async {
          final value = await secure.handle(call);
          if (fail &&
              call.method == 'write' &&
              (call.arguments as Map)['key'] == field) {
            throw PlatformException(
              code: 'synthetic',
              message: 'private-platform-payload',
            );
          }
          return value;
        });
        await expectLater(
          KeeneticCredentialsStore().save(
            baseUrl: 'https://new.invalid',
            username: 'new',
            password: 'replacement',
          ),
          throwsA(isA<DirectHomeAccessException>()),
        );
        expect(secure.values[marker], '1');
        await expectLater(
          KeeneticCredentialsStore().read(),
          throwsA(isA<DirectHomeAccessException>()),
        );
        fail = false;
        await KeeneticCredentialsStore().save(
          baseUrl: 'https://new.invalid',
          username: 'new',
          password: 'replacement',
        );
        expect(secure.values.containsKey(marker), isFalse);
        expect(
          (await KeeneticCredentialsStore().read())!.password,
          'replacement',
        );
      },
    );
    test(
      'source changes after reading $field prevent continued tuple publication',
      () async {
        final (c, home) = await routinesHome('direct');
        final store = c.read(keeneticCredentialsStoreProvider);
        messenger.setMockMethodCallHandler(channel, (call) async {
          final value = await secure.handle(call);
          if (call.method == 'read' &&
              (call.arguments as Map)['key'] == field) {
            await home.choose(HomeSource.verifiedCore);
          }
          return value;
        });
        await expectLater(
          store.read(),
          throwsA(isA<DirectHomeAccessException>()),
        );
        final last = secure.calls.last;
        expect(last, ('read', field));
      },
    );
  }

  test('queued read cannot borrow fresh authority after Direct Core Direct roundtrip', () async {
    final (c, home) = await routinesHome('direct');
    final store = c.read(keeneticCredentialsStoreProvider);
    final entered = Completer<void>(), released = Completer<void>();
    final blocking = ConfigurationWrites.run(() async {
      entered.complete();
      await released.future;
    });
    await entered.future;
    final reading = store.read();
    final rejected = expectLater(
      reading,
      throwsA(isA<DirectHomeAccessException>()),
    );
    await home.choose(HomeSource.verifiedCore);
    await home.choose(HomeSource.directLocal);
    home.runtimeMounted(home.runtimeIdentity);
    released.complete();
    await blocking;
    await rejected;
    expect(secure.calls, isEmpty);
  });

  test(
    'explicit clear removes the complete pending tuple with no router I/O',
    () async {
      secure.values[marker] = '1';
      await KeeneticCredentialsStore().clear();
      expect(secure.values, isEmpty);
      expect(await KeeneticCredentialsStore().read(), isNull);
    },
  );
}
