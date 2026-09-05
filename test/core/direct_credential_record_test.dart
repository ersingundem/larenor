import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/core/direct_credential_record.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/media/arr/data/arr_credentials_store.dart';

import 'direct_arr_credentials_test.dart';
import 'direct_home_routines_test.dart' show routinesHome;

class FaultPlatform extends ArrSecurePlatform {
  int? failAt;
  bool after = false;
  Future<void> Function(MethodCall)? afterEffect;
  @override
  Future<Object?> handle(MethodCall call) async {
    if (!after && calls.length == failAt) {
      calls.add((call.method, (call.arguments as Map)['key'] as String?));
      throw PlatformException(
        code: 'synthetic-secret',
        message: 'private-value',
      );
    }
    final result = await super.handle(call);
    await afterEffect?.call(call);
    if (after && calls.length - 1 == failAt) {
      throw PlatformException(
        code: 'synthetic-secret',
        message: 'private-value',
      );
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FaultPlatform secure;
  late FlutterSecureStoragePlatform previous;
  setUp(() {
    secure = FaultPlatform();
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
    for (final clear in [false, true]) {
      for (final after in [false, true]) {
        for (var step = 0; step < 4; step++) {
          test(
            '$name ${clear ? "clear" : "save"} stage$step ${after ? "after" : "before"} effect has static uncertainty and no repair',
            () async {
              final marker = '${name}_connection_pending_v1';
              secure.failAt = step;
              secure.after = after;
              final store = ArrCredentialsStore(servicePrefix: name);
              await expectLater(
                clear
                    ? store.clear()
                    : store.save(
                        baseUrl: 'https://new.invalid',
                        apiKey: 'synthetic-new',
                      ),
                throwsA(
                  isA<DirectHomeAccessException>()
                      .having((e) => e.code, 'code', 'write_unconfirmed')
                      .having(
                        (e) => e.toString(),
                        'safe error',
                        isNot(contains('private-value')),
                      ),
                ),
              );
              expect(
                secure.calls.length,
                step + 1,
              ); // No retry, rollback or cleanup.
              secure.failAt = null;
              secure.calls.clear();
              final freshStore = ArrCredentialsStore(servicePrefix: name);
              if (step == 0 && !after) {
                expect(
                  (await freshStore.read())!.baseUrl,
                  'https://old.invalid',
                );
              } else if (step == 3 && after) {
                // Lost final marker-delete ACK: the complete tuple is coherent.
                final result = await freshStore.read();
                if (clear) {
                  expect(result, isNull);
                } else {
                  expect(result!.baseUrl, 'https://new.invalid');
                  expect(result.apiKey, 'synthetic-new');
                }
              } else {
                expect(secure.values[marker], '1');
                await expectLater(
                  freshStore.read(),
                  throwsA(
                    isA<DirectHomeAccessException>().having(
                      (e) => e.code,
                      'code',
                      'pending_mutation',
                    ),
                  ),
                );
                expect(secure.calls, [('read', marker)]);
                // Explicit full replacement/clear is the only recovery operation.
                if (clear) {
                  await freshStore.clear();
                  expect(await freshStore.read(), isNull);
                } else {
                  await freshStore.save(
                    baseUrl: 'https://recovery.invalid',
                    apiKey: 'synthetic-recovery',
                  );
                  expect(
                    (await freshStore.read())!.apiKey,
                    'synthetic-recovery',
                  );
                }
                expect(secure.values.containsKey(marker), isFalse);
              }
              final other = name == 'sonarr' ? 'radarr' : 'sonarr';
              expect(secure.values['${other}_api_key'], 'synthetic-old-key');
            },
          );
        }
      }
    }
    for (var step = 0; step < 3; step++) {
      test(
        '$name read retires after platform read $step without publishing a tuple',
        () async {
          final (c, home) = await routinesHome('direct');
          final sub = holdArr(c, name);
          addTearDown(sub.close);
          await arrConnection(c, name);
          final store = arrStore(c, name);
          secure.calls.clear();
          secure.afterEffect = (call) async {
            if (secure.calls.length == step + 1) {
              await home.choose(HomeSource.verifiedCore);
            }
          };
          await expectLater(
            store.read(),
            throwsA(isA<DirectHomeAccessException>()),
          );
          expect(secure.calls.length, step + 1);
        },
      );
    }
    test(
      '$name held store stays retired after round trip; Direct idle reads remain valid',
      () async {
        final (c, home) = await routinesHome('direct');
        final sub = holdArr(c, name);
        addTearDown(sub.close);
        await arrConnection(c, name);
        final store = arrStore(c, name);
        // No foreground/interaction permission is required for a local background read.
        expect(home.interaction.active, isFalse);
        expect((await store.read())!.apiKey, 'synthetic-old-key');
        await home.choose(HomeSource.verifiedCore);
        await home.choose(HomeSource.directLocal);
        secure.calls.clear();
        for (final op in <Future<void> Function()>[
          () async {
            await store.read();
          },
          () => store.save(baseUrl: 'https://new.invalid', apiKey: 'new'),
          store.clear,
        ]) {
          await expectLater(op(), throwsA(isA<DirectHomeAccessException>()));
        }
        expect(secure.calls, isEmpty);
      },
    );
  }

  test('replaceAll snapshots caller fields before waiting for the shared write queue', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final blocker = ConfigurationWrites.run(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final fields = {
      'baseUrl': 'https://snapshot.invalid',
      'apiKey': 'snapshot',
    };
    final record = DirectCredentialRecord(
      service: DirectCredentialService.sonarr,
    );
    final save = record.replaceAll(fields);
    fields['baseUrl'] = 'https://changed.invalid';
    fields['apiKey'] = 'changed';
    expect(secure.calls, isEmpty);
    release.complete();
    await blocker;
    await save;
    expect(await record.readFields(), {
      'baseUrl': 'https://snapshot.invalid',
      'apiKey': 'snapshot',
    });
    expect(record.toString(), 'DirectCredentialRecord');
  });

  test('read is serialized with incomplete replacement instead of observing its middle', () async {
    final entered = Completer<void>(), release = Completer<void>();
    secure.afterEffect = (call) async {
      if (call.method == 'write' &&
          (call.arguments as Map)['key'] == 'sonarr_base_url') {
        entered.complete();
        await release.future;
      }
    };
    final store = ArrCredentialsStore(servicePrefix: 'sonarr');
    final save = store.save(baseUrl: 'https://new.invalid', apiKey: 'new');
    await entered.future;
    var readDone = false;
    final read = store.read().then((value) {
      readDone = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(readDone, isFalse);
    expect(secure.calls, [
      ('write', 'sonarr_connection_pending_v1'),
      ('write', 'sonarr_base_url'),
    ]);
    release.complete();
    await save;
    expect((await read)!.apiKey, 'new');
  });

  test(
    'queued retired write never begins its marker or field effects',
    () async {
      final (c, home) = await routinesHome('direct');
      final sub = holdArr(c, 'sonarr');
      addTearDown(sub.close);
      await arrConnection(c, 'sonarr');
      final store = arrStore(c, 'sonarr');
      secure.calls.clear();
      final entered = Completer<void>(), release = Completer<void>();
      final blocker = ConfigurationWrites.run(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final saving = expectLater(
        store.save(baseUrl: 'https://new.invalid', apiKey: 'new'),
        throwsA(isA<DirectHomeAccessException>()),
      );
      await home.choose(HomeSource.verifiedCore);
      release.complete();
      await blocker;
      await saving;
      expect(secure.calls, isEmpty);
    },
  );

  for (final fields in <Map<String, String>>[
    {},
    {'baseUrl': 'x'},
    {'baseUrl': 'x', 'apiKey': 'y', 'unknown': 'z'},
    {'baseUrl': 'x', 'other': 'y'},
  ]) {
    test(
      'closed record rejects wrong field set ${fields.keys.join(",")}',
      () async {
        final record = DirectCredentialRecord(
          service: DirectCredentialService.sonarr,
        );
        expect(() => record.replaceAll(fields), throwsArgumentError);
        expect(secure.calls, isEmpty);
      },
    );
  }
  for (final scoped in [false, true]) {
    test('platform read errors remain static (scoped=$scoped)', () async {
      final (c, _) = await routinesHome('direct');
      final sub = holdArr(c, 'sonarr');
      addTearDown(sub.close);
      await arrConnection(c, 'sonarr');
      secure.calls.clear();
      secure.failAt = 0;
      final store = scoped
          ? arrStore(c, 'sonarr')
          : ArrCredentialsStore(servicePrefix: 'sonarr');
      await expectLater(
        store.read(),
        throwsA(
          isA<DirectHomeAccessException>()
              .having((e) => e.code, 'code', 'storage_failed')
              .having((e) => e.toString(), 'safe', isNot(contains('private'))),
        ),
      );
    });
  }
  test(
    'throwing or expired action callbacks cannot start queued mutations',
    () async {
      final record = DirectCredentialRecord(
        service: DirectCredentialService.sonarr,
      );
      for (final current in <bool Function()>[
        () => false,
        () => throw StateError('private-action'),
      ]) {
        await expectLater(
          record.replaceAll({
            'baseUrl': 'url',
            'apiKey': 'key',
          }, isCurrent: current),
          throwsA(isA<DirectHomeAccessException>()),
        );
        await expectLater(
          record.clear(isCurrent: current),
          throwsA(isA<DirectHomeAccessException>()),
        );
      }
      expect(secure.calls, isEmpty);
    },
  );
  final legacyKeys = <DirectCredentialService, Map<String, String>>{
    DirectCredentialService.jellyfin: {
      'baseUrl': 'jellyfin_base_url',
      'userId': 'jellyfin_user_id',
      'accessToken': 'jellyfin_access_token',
    },
    DirectCredentialService.jellyseerr: {
      'baseUrl': 'jellyseerr_base_url',
      'apiKey': 'jellyseerr_api_key',
    },
    DirectCredentialService.bazarr: {
      'baseUrl': 'bazarr_base_url',
      'apiKey': 'bazarr_api_key',
    },
    DirectCredentialService.prowlarr: {
      'baseUrl': 'prowlarr_base_url',
      'apiKey': 'prowlarr_api_key',
    },
    DirectCredentialService.qbittorrent: {
      'baseUrl': 'qbittorrent_base_url',
      'username': 'qbittorrent_username',
      'password': 'qbittorrent_password',
    },
    DirectCredentialService.keenetic: {
      'baseUrl': 'keenetic_base_url',
      'username': 'keenetic_username',
      'password': 'keenetic_password',
    },
    DirectCredentialService.proxmox: {
      'host': 'proxmox_host',
      'port': 'proxmox_port',
      'username': 'proxmox_username',
      'realm': 'proxmox_realm',
      'password': 'proxmox_password',
      'allowSelfSigned': 'proxmox_allow_self_signed',
    },
  };
  for (final entry in legacyKeys.entries) {
    test(
      '${entry.key.name} reserved closed specification preserves exact legacy key order',
      () async {
        // Contract coverage only: these seven production consumers are not migrated.
        final record = DirectCredentialRecord(service: entry.key);
        final fields = {
          for (final field in entry.value.keys) field: 'synthetic-$field',
        };
        await record.replaceAll(fields);
        expect(secure.calls, [
          ('write', entry.key.pendingMutationKey),
          for (final key in entry.value.values) ('write', key),
          ('delete', entry.key.pendingMutationKey),
        ]);
        expect(await record.readFields(), fields);
        await record.clear();
        expect((await record.readFields()).values, everyElement(isNull));
      },
    );
  }
  for (final service in DirectCredentialService.values) {
    test(
      '${service.name} private marker identity is unique and never a field',
      () async {
        expect(
          DirectCredentialService.values
              .map((s) => s.pendingMutationKey)
              .toSet(),
          hasLength(11),
        );
        secure.values[service.pendingMutationKey] =
            'unexpected-value-still-pending';
        await expectLater(
          DirectCredentialRecord(service: service).readFields(),
          throwsA(
            isA<DirectHomeAccessException>().having(
              (e) => e.code,
              'code',
              'pending_mutation',
            ),
          ),
        );
        expect(secure.calls, [('read', service.pendingMutationKey)]);
      },
    );
  }
}
