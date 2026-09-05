import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/media/arr/providers/sonarr_providers.dart';
import 'package:larenor/features/media/arr/providers/radarr_providers.dart';
import 'package:larenor/features/media/arr/providers/lidarr_providers.dart';
import 'package:larenor/features/media/arr/providers/readarr_providers.dart';

import 'direct_arr_credentials_test.dart';
import 'direct_home_routines_test.dart' show routinesHome;

typedef SignIn = Future<void> Function({required String baseUrl, required String apiKey});
SignIn arrSignIn(ProviderContainer c, String name) => switch(name) {
  'sonarr' => c.read(sonarrConnectionProvider.notifier).signIn,
  'radarr' => c.read(radarrConnectionProvider.notifier).signIn,
  'lidarr' => c.read(lidarrConnectionProvider.notifier).signIn,
  _ => c.read(readarrConnectionProvider.notifier).signIn,
};
Future<void> Function() arrSignOut(ProviderContainer c, String name) => switch(name) {
  'sonarr' => c.read(sonarrConnectionProvider.notifier).signOut,
  'radarr' => c.read(radarrConnectionProvider.notifier).signOut,
  'lidarr' => c.read(lidarrConnectionProvider.notifier).signOut,
  _ => c.read(readarrConnectionProvider.notifier).signOut,
};
class TrackedArrHttp extends MockClient {
  TrackedArrHttp(super.handler, this.onClose);
  final void Function() onClose;
  @override
  void close() { onClose(); super.close(); }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ArrSecurePlatform secure;
  late FlutterSecureStoragePlatform previous;
  setUp(() {
    secure = ArrSecurePlatform();
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), secure.handle,
    );
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), null,
    );
  });
  for (final name in arrServices) {
    test('$name cold Core signIn must reject before creating network client', () async {
      var requests = 0, clients = 0;
      await http.runWithClient(() async {
        final (c, _) = await routinesHome('core');
        final sub = holdArr(c, name); addTearDown(sub.close);
        await expectLater(arrConnection(c, name), throwsA(isA<DirectHomeAccessException>()));
        secure.calls.clear();
        await expectLater(arrSignIn(c,name)(baseUrl:'https://fixture.invalid',apiKey:'synthetic'),
          throwsA(isA<DirectHomeAccessException>()));
        expect(clients, 0); expect(requests, 0); expect(secure.calls, isEmpty);
      }, () { clients++; return MockClient((_) async {requests++; return http.Response('{}',200);}); });
    });
    test('$name late login after Direct Core Direct cannot reacquire a fresh store', () async {
      final response = Completer<http.Response>();
      final dispatched = Completer<void>();
      await http.runWithClient(() async {
        final (c, home) = await routinesHome('direct');
        final sub = holdArr(c, name); addTearDown(sub.close);
        await arrConnection(c, name);
        final login = arrSignIn(c,name);
        final pending = login(baseUrl:'https://new.invalid',apiKey:'synthetic-new');
        final rejected = expectLater(pending, throwsA(isA<DirectHomeAccessException>()));
        await dispatched.future;
        await home.choose(HomeSource.verifiedCore);
        await home.choose(HomeSource.directLocal);
        home.runtimeMounted(home.runtimeIdentity);
        await Future<void>.delayed(Duration.zero);
        secure.calls.clear();
        response.complete(http.Response('{}',200));
        await rejected;
        expect(secure.calls.where((c)=>c.$1 != 'read'), isEmpty);
        expect(secure.values['${name}_base_url'], 'https://old.invalid');
      }, () => MockClient((_) { if (!dispatched.isCompleted) dispatched.complete(); return response.future; }));
    });
    test('$name old signOut after Direct Core Direct cannot clear saved credentials', () async {
      final (c, home) = await routinesHome('direct');
      final sub = holdArr(c, name); addTearDown(sub.close); await arrConnection(c,name);
      final logout = arrSignOut(c,name);
      await home.choose(HomeSource.verifiedCore); await home.choose(HomeSource.directLocal);
      home.runtimeMounted(home.runtimeIdentity); await Future<void>.delayed(Duration.zero);
      secure.calls.clear();
      await expectLater(logout(), throwsA(isA<DirectHomeAccessException>()));
      expect(secure.calls, isEmpty);
    });
    test('$name successful current login closes its one-use check transport', () async {
      var closed = 0;
      await http.runWithClient(() async {
        final (c, _) = await routinesHome('direct');
        final sub = holdArr(c, name); addTearDown(sub.close); await arrConnection(c,name);
        await arrSignIn(c,name)(baseUrl:'https://new.invalid',apiKey:'synthetic-new');
        expect((await arrConnection(c,name))!.baseUrl, 'https://new.invalid');
        expect(closed, 1);
      }, () => TrackedArrHttp((_) async => http.Response('{}',200), ()=>closed++));
    });
  }
}
