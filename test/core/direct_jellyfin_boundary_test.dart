
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// The pinned secure-storage plugin's real platform boundary.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/core/direct_credential_record.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_credentials_store.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';

import 'direct_home_boundary_test.dart' show SecurePlatform;
import 'direct_home_routines_test.dart' show routinesHome;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecurePlatform secure;
  late FlutterSecureStoragePlatform previous;
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final marker = DirectCredentialService.jellyfin.pendingMutationKey;
  const original = {
    'jellyfin_base_url': 'https://old.invalid',
    'jellyfin_user_id': 'synthetic-user',
    'jellyfin_access_token': 'synthetic-old-accessToken',
    'jellyfin_device_id': 'synthetic-device',
  };
  setUp(() {
    secure = SecurePlatform()
      ..values.clear()
      ..values.addAll(original);
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
      '$mode actual Jellyfin provider cannot read Direct credentials',
      () async {
        final (c, _) = await routinesHome(mode);
        final sub = c.listen(jellyfinConnectionProvider, (_, _) {});
        addTearDown(sub.close);
        await expectLater(
          c.read(jellyfinConnectionProvider.future),
          throwsA(isA<DirectHomeAccessException>()),
        );
        expect(secure.calls, isEmpty);
      },
    );
  }
  test('held Core Jellyfin store cannot read save or clear', () async {
    final (c, _) = await routinesHome('core');
    final store = c.read(jellyfinCredentialsStoreProvider);
    for (final operation in <Future<void> Function()>[
      () async {
        await store.read();
      },
      () => store.save(
        baseUrl: 'https://new.invalid',
        userId: 'new-user',
        accessToken: 'new-accessToken',
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
  test('held store is permanently retired after Direct Core Direct', () async {
    final (c, home) = await routinesHome('direct');
    final store = c.read(jellyfinCredentialsStoreProvider);
    expect((await store.read())!.baseUrl, original['jellyfin_base_url']);
    await home.choose(HomeSource.verifiedCore);
    await home.choose(HomeSource.directLocal);
    home.runtimeMounted(home.runtimeIdentity);
    secure.calls.clear();
    await expectLater(store.clear(), throwsA(isA<DirectHomeAccessException>()));
    expect(secure.calls, isEmpty);
    expect(secure.values, original);
  });
  for (final value in ['1', '', 'false', 'synthetic-private-marker']) {
    test(
      'pending marker length ${value.length} blocks all tuple reads',
      () async {
        secure.values[marker] = value;
        await expectLater(
          JellyfinCredentialsStore().read(),
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
  for (final field in original.keys.where((key) => key != 'jellyfin_device_id')) {
    test(
      'uncertain $field effect is quarantined until explicit complete save',
      () async {
        var fail = true;
        messenger.setMockMethodCallHandler(channel, (call) async {
          final result = await secure.handle(call);
          if (fail &&
              call.method == 'write' &&
              (call.arguments as Map)['key'] == field) {
            throw PlatformException(
              code: 'synthetic',
              message: 'synthetic-private-accessToken',
            );
          }
          return result;
        });
        final store = JellyfinCredentialsStore();
        await expectLater(
          store.save(
            baseUrl: 'https://new.invalid',
            userId: 'new-user',
            accessToken: 'new-accessToken',
          ),
          throwsA(isA<DirectHomeAccessException>()),
        );
        expect(secure.values[marker], '1');
        await expectLater(
          JellyfinCredentialsStore().read(),
          throwsA(isA<DirectHomeAccessException>()),
        );
        fail = false;
        await store.save(
          baseUrl: 'https://new.invalid',
          userId: 'new-user',
          accessToken: 'new-accessToken',
        );
        expect(secure.values.containsKey(marker), isFalse);
        final config = await JellyfinCredentialsStore().read();
        expect(config!.baseUrl, 'https://new.invalid');
        expect(config.userId, 'new-user');
        expect(config.accessToken, 'new-accessToken');
      },
    );
  }
  test('pending connection is explicitly removable without a login', () async {
    secure.values[marker] = '1';
    await JellyfinCredentialsStore().clear();
    expect(secure.values, {'jellyfin_device_id': 'synthetic-device'});
    expect(await JellyfinCredentialsStore().read(), isNull);
  });


  test('cold Core cannot read or create a Jellyfin device identity', () async {
    secure.values.remove('jellyfin_device_id');
    final (c, _) = await routinesHome('core');
    final store = c.read(jellyfinCredentialsStoreProvider);
    await expectLater(store.deviceId(), throwsA(isA<DirectHomeAccessException>()));
    expect(secure.calls, isEmpty);
  });

  test('source lost during device-id read cannot generate and write a new id', () async {
    secure.values.remove('jellyfin_device_id');
    final (c, home) = await routinesHome('direct');
    final store = c.read(jellyfinCredentialsStoreProvider);
    messenger.setMockMethodCallHandler(channel, (call) async {
      final value = await secure.handle(call);
      if (call.method == 'read' && (call.arguments as Map)['key'] == 'jellyfin_device_id') {
        await home.choose(HomeSource.verifiedCore);
      }
      return value;
    });
    await expectLater(store.deviceId(), throwsA(isA<DirectHomeAccessException>()));
    expect(secure.calls.where((call) => call.$1 != 'read'), isEmpty);
    expect(secure.values.containsKey('jellyfin_device_id'), isFalse);
  });

  test('device identity is stable across explicit record save and clear', () async {
    final store = JellyfinCredentialsStore();
    expect(await store.deviceId(), 'synthetic-device');
    await store.save(baseUrl: 'https://new.invalid', userId: 'new-user', accessToken: 'new-token');
    expect((await store.read())!.deviceId, 'synthetic-device');
    await store.clear();
    expect(await store.deviceId(), 'synthetic-device');
    expect(await store.read(), isNull);
  });
  for (final mode in ['pending', 'error']) {
    test('$mode cannot even read the separate device identity', () async {
      final (c, _) = await routinesHome(mode);
      await expectLater(c.read(jellyfinCredentialsStoreProvider).deviceId(), throwsA(isA<DirectHomeAccessException>()));
      expect(secure.calls, isEmpty);
    });
  }
  test('held device identity access never revives after source roundtrip', () async {
    final (c, home) = await routinesHome('direct');
    final store = c.read(jellyfinCredentialsStoreProvider);
    expect(await store.deviceId(), 'synthetic-device');
    await home.choose(HomeSource.verifiedCore);await home.choose(HomeSource.directLocal);
    secure.calls.clear();await expectLater(store.deviceId(), throwsA(isA<DirectHomeAccessException>()));expect(secure.calls, isEmpty);
  });
  test('pending tuple read never generates an absent device identity', () async {
    secure.values.remove('jellyfin_device_id');secure.values[marker] = '1';
    await expectLater(JellyfinCredentialsStore().read(), throwsA(isA<DirectHomeAccessException>()));
    expect(secure.calls, [('read', marker)]);expect(secure.values.containsKey('jellyfin_device_id'), isFalse);
  });
  test('two explicit device identity requests serialize one creation and preserve it on clear', () async {
    secure.values.remove('jellyfin_device_id');final store=JellyfinCredentialsStore();
    final ids=await Future.wait([store.deviceId(), store.deviceId()]);expect(ids[0], startsWith('larenor-'));expect(ids[1],ids[0]);expect(secure.calls.where((call)=>call.$1=='write'), hasLength(1));
    await store.clear();expect(await JellyfinCredentialsStore().deviceId(), ids[0]);
  });
  test('wrong device storage type is a static read failure without replacement', () async {
    messenger.setMockMethodCallHandler(channel,(call) async {await secure.handle(call);return {'private':'secret'};});
    await expectLater(JellyfinCredentialsStore().deviceId(), throwsA(isA<DirectHomeAccessException>().having((e)=>e.code,'code','storage_failed')));
    expect(secure.calls, [('read','jellyfin_device_id')]);
  });
  for(final after in [false,true]) {
    test('device identity lost write response afterEffect=$after is not automatically repaired', () async {
      secure.values.remove('jellyfin_device_id');
      messenger.setMockMethodCallHandler(channel,(call) async {
        if(call.method=='write') {if(after) await secure.handle(call);throw PlatformException(code:'private',message:'sentinel-device');}
        return secure.handle(call);
      });
      await expectLater(JellyfinCredentialsStore().deviceId(), throwsA(isA<DirectHomeAccessException>().having((e)=>e.code,'code','write_unconfirmed').having((e)=>e.toString(),'static',isNot(contains('sentinel-device')))));
      expect(secure.values.containsKey('jellyfin_device_id'), after);
      expect(secure.calls.where((call)=>call.$1=='write').length, after?1:0);
      if(after) {final id=secure.values['jellyfin_device_id'];messenger.setMockMethodCallHandler(channel,secure.handle);expect(await JellyfinCredentialsStore().deviceId(),id);}
    });
  }
  for(final clear in [false,true]) {
    for(final after in [false,true]) {
      for(var stage=0;stage<5;stage++) {
        test('tuple ${clear?'clear':'save'} stage$stage afterEffect=$after quarantines partial effects', () async {
          var effects=0;
          messenger.setMockMethodCallHandler(channel,(call) async {
            if(call.method=='read') return secure.handle(call);
            final failing=effects++==stage;
            if(failing&&!after) throw PlatformException(code:'private',message:'sentinel-token');
            final result=await secure.handle(call);
            if(failing) throw PlatformException(code:'private',message:'sentinel-token');
            return result;
          });
          final store=JellyfinCredentialsStore();
          await expectLater(clear?store.clear():store.save(baseUrl:'https://new.invalid',userId:'new-user',accessToken:'new-token'),throwsA(isA<DirectHomeAccessException>().having((e)=>e.code,'code','write_unconfirmed')));
          expect(effects,stage+1);expect(secure.values['jellyfin_device_id'],'synthetic-device');
          messenger.setMockMethodCallHandler(channel,secure.handle);secure.calls.clear();
          final fresh=JellyfinCredentialsStore();
          if(stage==0&&!after) {expect((await fresh.read())!.accessToken,'synthetic-old-accessToken');}
          else if(stage==4&&after) {expect((await fresh.read())?.accessToken,clear?isNull:'new-token');}
          else {await expectLater(fresh.read(),throwsA(isA<DirectHomeAccessException>().having((e)=>e.code,'code','pending_mutation')));expect(secure.calls,[('read',marker)]);await fresh.clear();expect(await fresh.read(),isNull);}
          expect(secure.values['jellyfin_device_id'],'synthetic-device');
        });
      }
    }
  }

}
