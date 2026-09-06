import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// The pinned secure-storage plugin's real platform boundary.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/direct_credential_record.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/media/qbittorrent/data/qbittorrent_credentials_store.dart';
import 'package:larenor/features/media/qbittorrent/providers/qbittorrent_providers.dart';

import 'direct_home_boundary_test.dart' show SecurePlatform;
import 'direct_home_routines_test.dart' show routinesHome;
import '../features/media/qbittorrent/qbittorrent_providers_test.dart'
    show success, ClosingHttp;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecurePlatform secure;
  late FlutterSecureStoragePlatform previous;
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final marker = DirectCredentialService.qbittorrent.pendingMutationKey;
  const original = {
    'qbittorrent_base_url': 'https://old.invalid',
    'qbittorrent_username': 'synthetic-user',
    'qbittorrent_password': 'synthetic-old-password',
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
      '$mode actual qBittorrent provider cannot read Direct credentials',
      () async {
        final (c, _) = await routinesHome(mode);
        final sub = c.listen(qbittorrentConnectionProvider, (_, _) {});
        addTearDown(sub.close);
        await expectLater(
          c.read(qbittorrentConnectionProvider.future),
          throwsA(isA<DirectHomeAccessException>()),
        );
        expect(secure.calls, isEmpty);
      },
    );
  }
  test('held Core qBittorrent store cannot read save or clear', () async {
    final (c, _) = await routinesHome('core');
    final store = c.read(qbittorrentCredentialsStoreProvider);
    for (final operation in <Future<void> Function()>[
      () async {
        await store.read();
      },
      () => store.save(
        baseUrl: 'https://new.invalid',
        username: 'new-user',
        password: 'new-password',
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
    final store = c.read(qbittorrentCredentialsStoreProvider);
    expect((await store.read())!.baseUrl, original['qbittorrent_base_url']);
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
          QbittorrentCredentialsStore().read(),
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
  for (final field in original.keys) {
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
              message: 'synthetic-private-password',
            );
          }
          return result;
        });
        final store = QbittorrentCredentialsStore();
        await expectLater(
          store.save(
            baseUrl: 'https://new.invalid',
            username: 'new-user',
            password: 'new-password',
          ),
          throwsA(isA<DirectHomeAccessException>()),
        );
        expect(secure.values[marker], '1');
        await expectLater(
          QbittorrentCredentialsStore().read(),
          throwsA(isA<DirectHomeAccessException>()),
        );
        fail = false;
        await store.save(
          baseUrl: 'https://new.invalid',
          username: 'new-user',
          password: 'new-password',
        );
        expect(secure.values.containsKey(marker), isFalse);
        final config = await QbittorrentCredentialsStore().read();
        expect(config!.baseUrl, 'https://new.invalid');
        expect(config.username, 'new-user');
        expect(config.password, 'new-password');
      },
    );
  }
  test('pending connection is explicitly removable without a login', () async {
    secure.values[marker] = '1';
    await QbittorrentCredentialsStore().clear();
    expect(secure.values, isEmpty);
    expect(await QbittorrentCredentialsStore().read(), isNull);
  });

  test(
    'cold Core sign-in rejects before creating any cookie transport',
    () async {
      var clients = 0, requests = 0;
      await http.runWithClient(
        () async {
          final (c, _) = await routinesHome('core');
          final sub = c.listen(qbittorrentConnectionProvider, (_, _) {});
          addTearDown(sub.close);
          await expectLater(
            c.read(qbittorrentConnectionProvider.future),
            throwsA(isA<DirectHomeAccessException>()),
          );
          secure.calls.clear();
          await expectLater(
            c
                .read(qbittorrentConnectionProvider.notifier)
                .signIn(
                  baseUrl: 'https://new.invalid',
                  username: 'new-user',
                  password: 'new-password',
                ),
            throwsA(isA<DirectHomeAccessException>()),
          );
          expect(clients, 0);
          expect(requests, 0);
          expect(secure.calls, isEmpty);
        },
        () {
          clients++;
          return MockClient((request) async {
            requests++;
            return success(request);
          });
        },
      );
    },
  );

  test(
    'held sign-out after source roundtrip cannot clear a new owner',
    () async {
      final (c, home) = await routinesHome('direct');
      final sub = c.listen(qbittorrentConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(qbittorrentConnectionProvider.future);
      final signOut = c.read(qbittorrentConnectionProvider.notifier).signOut;
      await home.choose(HomeSource.verifiedCore);
      await home.choose(HomeSource.directLocal);
      home.runtimeMounted(home.runtimeIdentity);
      await Future<void>.delayed(Duration.zero);
      secure.calls.clear();
      await expectLater(signOut(), throwsA(isA<DirectHomeAccessException>()));
      expect(secure.calls, isEmpty);
    },
  );

  test('late login after source roundtrip cannot reacquire and save through a fresh store', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    await http.runWithClient(
      () async {
        final (c, home) = await routinesHome('direct');
        final sub = c.listen(qbittorrentConnectionProvider, (_, _) {});
        addTearDown(sub.close);
        await c.read(qbittorrentConnectionProvider.future);
        final pending = c
            .read(qbittorrentConnectionProvider.notifier)
            .signIn(
              baseUrl: 'https://new.invalid',
              username: 'new-user',
              password: 'new-password',
            );
        final rejected = expectLater(
          pending,
          throwsA(isA<DirectHomeAccessException>()),
        );
        await started.future;
        await home.choose(HomeSource.verifiedCore);
        await home.choose(HomeSource.directLocal);
        home.runtimeMounted(home.runtimeIdentity);
        await Future<void>.delayed(Duration.zero);
        secure.calls.clear();
        response.complete(
          http.Response(
            '',
            204,
            headers: {'set-cookie': 'SID=synthetic; Path=/'},
          ),
        );
        await rejected;
        expect(secure.calls.where((call) => call.$1 != 'read'), isEmpty);
        expect(secure.values, original);
      },
      () => MockClient((request) async {
        if (request.url.path.endsWith('/auth/login')) {
          if (!started.isCompleted) started.complete();
          return response.future;
        }
        return success(request);
      }),
    );
  });
  for (final throws in [false, true]) {
    test(
      'expired callback (throws=$throws) refuses sign-in before transport or storage',
      () async {
        final (c, _) = await routinesHome('direct');
        final sub = c.listen(qbittorrentConnectionProvider, (_, _) {});
        addTearDown(sub.close);
        await c.read(qbittorrentConnectionProvider.future);
        secure.calls.clear();
        var requests = 0;
        await http.runWithClient(
          () async {
            await expectLater(
              c
                  .read(qbittorrentConnectionProvider.notifier)
                  .signIn(
                    baseUrl: 'https://new.invalid',
                    username: 'new-user',
                    password: 'new-password',
                    isCurrent: () =>
                        throws ? throw StateError('synthetic secret') : false,
                  ),
              throwsA(isA<DirectHomeAccessException>()),
            );
          },
          () => MockClient((request) async {
            requests++;
            return success(request);
          }),
        );
        expect(requests, 0);
        expect(secure.calls, isEmpty);
      },
    );
  }

  test('wrong or former cancellation owner cannot close the newest verifier or normal reader', () async {
    final oldResponse = Completer<http.Response>(),
        newResponse = Completer<http.Response>();
    final startedOld = Completer<void>(), startedNew = Completer<void>();
    final transports = <ClosingHttp>[];
    final requests = <http.Request>[];
    await http.runWithClient(
      () async {
        final (c, _) = await routinesHome('direct');
        final sub = c.listen(qbittorrentConnectionProvider, (_, _) {});
        addTearDown(sub.close);
        await c.read(qbittorrentConnectionProvider.future);
        final connection = c.read(qbittorrentConnectionProvider.notifier);
        bool oldOwner() => true;
        bool newOwner() => true;
        final old = connection.signIn(
          baseUrl: 'https://first.invalid',
          username: 'one',
          password: 'one-fixture',
          isCurrent: oldOwner,
        );
        final rejected = expectLater(old, throwsA(isA<Exception>()));
        await startedOld.future;
        final next = connection.signIn(
          baseUrl: 'https://new.invalid',
          username: 'two',
          password: 'two-fixture',
          isCurrent: newOwner,
        );
        await startedNew.future;
        connection.cancelSignIn(oldOwner);
        connection.cancelSignIn(() => true);
        expect(transports.last.closed, isFalse);
        oldResponse.complete(
          http.Response('', 204, headers: {'set-cookie': 'SID=old; Path=/'}),
        );
        newResponse.complete(
          http.Response('', 204, headers: {'set-cookie': 'SID=new; Path=/'}),
        );
        await rejected;
        await next;
        expect(secure.values['qbittorrent_password'], 'two-fixture');
        expect(
          requests.where((r) => r.url.host == 'first.invalid'),
          hasLength(1),
        );
        final readerSub = c.listen(qbittorrentClientProvider, (_, _) {});
        addTearDown(readerSub.close);
        final reader = await c.read(qbittorrentClientProvider.future);
        expect(reader!.isAuthenticated, isTrue);
        final count = requests.length;
        connection.cancelSignIn(newOwner);
        expect(reader.isAuthenticated, isTrue);
        expect(requests.length, count);
      },
      () {
        late ClosingHttp transport;
        transport = ClosingHttp((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/auth/login')) {
            if (request.url.host == 'first.invalid') {
              startedOld.complete();
              return oldResponse.future;
            }
            if (!startedNew.isCompleted) {
              startedNew.complete();
              return newResponse.future;
            }
          }
          return success(request);
        });
        transports.add(transport);
        return transport;
      },
    );
  });

  test('cancelled replacement never republishes old configuration to restart a cookie reader', () async {
    final response = Completer<http.Response>(), entered = Completer<void>();
    final requests = <http.Request>[];
    await http.runWithClient(
      () async {
        final (c, _) = await routinesHome('direct');
        final sub = c.listen(qbittorrentClientProvider, (_, _) {});
        addTearDown(sub.close);
        await c.read(qbittorrentConnectionProvider.future);
        await c.pump();
        final reader = await c.read(qbittorrentClientProvider.future);
        expect(reader!.isAuthenticated, isTrue);
        expect(requests, hasLength(3));
        final connection = c.read(qbittorrentConnectionProvider.notifier);
        var active = true;
        bool owner() => active;
        final pending = connection.signIn(
          baseUrl: 'https://new.invalid',
          username: 'new',
          password: 'new-fixture',
          isCurrent: owner,
        );
        final rejected = expectLater(
          pending,
          throwsA(isA<DirectHomeAccessException>()),
        );
        await entered.future;
        active = false;
        connection.cancelSignIn(owner);
        response.complete(
          http.Response('', 204, headers: {'set-cookie': 'SID=new; Path=/'}),
        );
        await rejected;
        await c.pump();
        expect(c.read(qbittorrentConnectionProvider).hasError, isTrue);
        expect(await c.read(qbittorrentClientProvider.future), isNull);
        expect(requests, hasLength(4));
        expect(reader.isAuthenticated, isFalse);
        expect(secure.values, original);
      },
      () => MockClient((request) async {
        requests.add(request);
        if (request.url.host == 'new.invalid') {
          entered.complete();
          return response.future;
        }
        return success(request);
      }),
    );
  });

  test('HTTP-verified partial tuple failure never becomes a usable connection or automatic reader', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      final result = await secure.handle(call);
      if (call.method == 'write' &&
          (call.arguments as Map)['key'] == 'qbittorrent_base_url') {
        throw PlatformException(
          code: 'synthetic',
          message: 'synthetic-private-password',
        );
      }
      return result;
    });
    var requests = 0;
    await http.runWithClient(
      () async {
        final (c, _) = await routinesHome('direct');
        final sub = c.listen(qbittorrentConnectionProvider, (_, _) {});
        addTearDown(sub.close);
        await c.read(qbittorrentConnectionProvider.future);
        await expectLater(
          c
              .read(qbittorrentConnectionProvider.notifier)
              .signIn(
                baseUrl: 'https://new.invalid',
                username: 'new',
                password: 'new-fixture',
                isCurrent: () => true,
              ),
          throwsA(isA<DirectHomeAccessException>()),
        );
        expect(requests, 3);
        expect(c.read(qbittorrentConnectionProvider).hasError, isTrue);
        expect(await c.read(qbittorrentClientProvider.future), isNull);
        expect(requests, 3);
        expect(secure.values[marker], '1');
        expect(
          secure.values['qbittorrent_username'],
          original['qbittorrent_username'],
        );
        expect(
          secure.values['qbittorrent_password'],
          original['qbittorrent_password'],
        );
        c.invalidate(qbittorrentConnectionProvider);
        await expectLater(
          c.read(qbittorrentConnectionProvider.future),
          throwsA(isA<DirectHomeAccessException>()),
        );
        expect(requests, 3);
      },
      () => MockClient((request) async {
        requests++;
        return success(request);
      }),
    );
  });
}
