import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/intercom/domain/door_station.dart';
import 'package:larenor/features/intercom/providers/intercom_providers.dart';
import 'package:larenor/features/media/movie_night/domain/movie_night_preset.dart';
import 'package:larenor/features/media/movie_night/presentation/movie_night_launcher.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'direct_home_boundary_test.dart' as home_fixture;
import '../features/intercom/door_station_test.dart' show fixtureStation;
import '../features/media/movie_night/movie_night_runner_test.dart' show preset;

class RoutinesPreferences extends InMemorySharedPreferencesStore {
  RoutinesPreferences() : super.withData({
    'flutter.${DoorStation.storageKey}': DoorStation.encodeStored([fixtureStation]),
    'flutter.${MovieNightPreset.storageKey}': preset.encodeStored(),
  });
  int reads = 0;
  final writes = <String>[];
  Future<void> Function()? afterRead;
  Future<void> Function()? afterWrite;
  bool failWrite = false;
  bool throwWrite = false;
  @override
  Future<Map<String,Object>> getAll() async {
    reads++;
    final result = await super.getAll();
    await afterRead?.call();
    return result;
  }
  @override
  Future<bool> setValue(String type,String key,Object value) async {
    writes.add(key);
    if (throwWrite) throw const FormatException('sentinel-private-home');
    if (failWrite) return false;
    final result = await super.setValue(type,key,value);
    await afterWrite?.call();
    return result;
  }
}
class _Source extends home_fixture.SourceStore {
  _Source(super.value);
  Completer<HomeSource>? pending;
  bool fail = false;
  @override
  Future<HomeSource> read() async {
    if (fail) throw StateError('private-source');
    return pending == null ? value : pending!.future;
  }
}

Future<(ProviderContainer,HomeSessionController)> routinesHome(String mode) async {
  final source = _Source(mode == 'core' ? HomeSource.verifiedCore : HomeSource.directLocal);
  if (mode == 'pending') source.pending = Completer<HomeSource>();
  if (mode == 'error') source.fail = true;
  final account = ServerAccountController(store: home_fixture.SessionStore());
  final home = HomeSessionController(store:source,account:account);
  final initializing = home.initialize();
  if (mode != 'pending') await initializing;
  final container = ProviderContainer(overrides:[homeSessionControllerProvider.overrideWithValue(home)],retry:(_,_)=>null);
  addTearDown(() async {
    container.dispose(); home.dispose(); account.dispose();
    source.pending?.complete(HomeSource.directLocal);
    await initializing;
  });
  return (container,home);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RoutinesPreferences prefs;
  setUp(() {
    SharedPreferences.resetStatic();
    prefs = RoutinesPreferences();
    SharedPreferencesStorePlatform.instance = prefs;
  });
  for (final mode in ['core','pending','error']) {
    test('$mode actual intercom provider rejects without preference acquisition', () async {
      final (container,_) = await routinesHome(mode);
      final sub = container.listen(doorStationsProvider,(_,_){});
      addTearDown(sub.close);
      await expectLater(container.read(doorStationsProvider.future),throwsA(isA<DirectHomeAccessException>()));
      expect(prefs.reads,0); expect(prefs.writes,isEmpty);
    });
    test('$mode captured station store rejects read save upsert remove', () async {
      final (container,_) = await routinesHome(mode);
      final store = container.read(doorStationStoreProvider);
      for (final operation in <Future<void> Function()>[
        () async {await store.read();},
        () => store.save([fixtureStation]),
        () => store.upsert(fixtureStation),
        () => store.remove(fixtureStation.id),
      ]) {
        await expectLater(Future.sync(operation),throwsA(isA<DirectHomeAccessException>()));
      }
      expect(prefs.reads,0); expect(prefs.writes,isEmpty);
    });
    test('$mode captured movie store rejects read and save even with true caller guard', () async {
      final (container,_) = await routinesHome(mode);
      final store = container.read(movieNightStoreProvider);
      await expectLater(store.read(),throwsA(isA<DirectHomeAccessException>()));
      await expectLater(store.save(preset,isCurrent:()=>true),throwsA(isA<DirectHomeAccessException>()));
      expect(prefs.reads,0); expect(prefs.writes,isEmpty);
    });
  }
  for (final movie in [false,true]) {
    test('${movie ? 'movie' : 'station'} read reloads durable record after old preference cache',() async {
      await SharedPreferences.getInstance();
      await prefs.setValue('String', 'flutter.${movie ? MovieNightPreset.storageKey : DoorStation.storageKey}', movie ? const MovieNightPreset(serverUrl:'https://new.test',startEntityId:'scene.new').encodeStored() : DoorStation.encodeStored([]));
      final (container,home) = await routinesHome('direct');
      home.interaction.setActive(false);
      if (movie) {
        expect((await container.read(movieNightStoreProvider).read())?.startEntityId,'scene.new');
      } else {
        expect(await container.read(doorStationStoreProvider).read(),isEmpty);
      }
    });
    test('${movie ? 'movie' : 'station'} pending read rejects if source changes during platform response',() async {
      final (container,home) = await routinesHome('direct');
      prefs.afterRead = () => home.choose(HomeSource.verifiedCore);
      final read = movie ? container.read(movieNightStoreProvider).read() : container.read(doorStationStoreProvider).read();
      await expectLater(read,throwsA(isA<DirectHomeAccessException>()));
      expect(prefs.writes,isEmpty);
    });
    test('${movie ? 'movie' : 'station'} completed effect after source loss reports uncertainty without rollback',() async {
      final (container,home) = await routinesHome('direct');
      prefs.afterWrite = () => home.choose(HomeSource.verifiedCore);
      final write = movie ? container.read(movieNightStoreProvider).save(preset,isCurrent:()=>true) : container.read(doorStationStoreProvider).save([]);
      await expectLater(write,throwsA(isA<DirectHomeAccessException>().having((e)=>e.code,'code','write_unconfirmed')));
      expect(prefs.writes,hasLength(1));
      final durable = await prefs.getAll();
      expect(durable['flutter.${movie ? MovieNightPreset.storageKey : DoorStation.storageKey}'],movie ? preset.encodeStored() : DoorStation.encodeStored([]));
    });
  }
}
