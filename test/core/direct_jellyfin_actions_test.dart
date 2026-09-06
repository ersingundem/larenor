import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';

import 'direct_home_boundary_test.dart' show SecurePlatform;
import 'direct_home_routines_test.dart' show routinesHome;

class JellyfinClosingHttp extends MockClient {
  JellyfinClosingHttp(super.handler, this.onClose);
  final void Function() onClose;
  @override
  void close() {
    onClose();
    super.close();
  }
}

const jellyfinLoginBody =
    '{"AccessToken":"new-token","User":{"Id":"new-user"}}';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecurePlatform secure;
  late FlutterSecureStoragePlatform previous;
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    secure = SecurePlatform()..values['jellyfin_device_id'] = 'fixed-device';
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, secure.handle);
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  Future<void> ready(ProviderContainer c) async {
    final sub = c.listen(jellyfinConnectionProvider, (_, _) {});
    addTearDown(sub.close);
    await c.read(jellyfinConnectionProvider.future);
  }

  for (final mode in ['core', 'pending', 'error']) {
    test(
      '$mode real login rejects before HTTP factory or device-id access',
      () async {
        var clients = 0;
        await http.runWithClient(
          () async {
            final (c, _) = await routinesHome(mode);
            final sub = c.listen(jellyfinConnectionProvider, (_, _) {});
            addTearDown(sub.close);
            await expectLater(
              c.read(jellyfinConnectionProvider.future),
              throwsA(isA<DirectHomeAccessException>()),
            );
            secure.calls.clear();
            await expectLater(
              c
                  .read(jellyfinConnectionProvider.notifier)
                  .signIn(
                    baseUrl: 'https://new.invalid',
                    username: 'name',
                    password: 'password',
                  ),
              throwsA(isA<DirectHomeAccessException>()),
            );
            expect(clients, 0);
            expect(secure.calls, isEmpty);
          },
          () {
            clients++;
            return MockClient(
              (_) async => http.Response(jellyfinLoginBody, 200),
            );
          },
        );
      },
    );
  }
  test('retained logout never reacquires a later Direct source', () async {
    final (c, home) = await routinesHome('direct');
    await ready(c);
    final logout = c.read(jellyfinConnectionProvider.notifier).signOut;
    await home.choose(HomeSource.verifiedCore);
    await home.choose(HomeSource.directLocal);
    await c.pump();
    secure.calls.clear();
    await expectLater(
      Future.sync(logout),
      throwsA(isA<DirectHomeAccessException>()),
    );
    expect(secure.calls, isEmpty);
  });
  for (final retire in ['source', 'provider', 'logout']) {
    test(
      '$retire retires a pending login before its response and closes owned transport',
      () async {
        final sent = Completer<void>(), response = Completer<http.Response>();
        var closed = 0;
        await http.runWithClient(
          () async {
            final (c, home) = await routinesHome('direct');
            await ready(c);
            final notifier = c.read(jellyfinConnectionProvider.notifier);
            final future = notifier.signIn(
              baseUrl: 'https://new.invalid',
              username: 'name',
              password: 'password',
            );
            final rejected = expectLater(
              future,
              throwsA(isA<DirectHomeAccessException>()),
            );
            await sent.future;
            if (retire == 'source') {
              await home.choose(HomeSource.verifiedCore);
              await c.pump();
            } else if (retire == 'provider') {
              c.invalidate(jellyfinConnectionProvider);
              await c.pump();
            } else {
              await notifier.signOut();
            }
            final closedBeforeResponse = closed;
            secure.calls.clear();
            response.complete(http.Response(jellyfinLoginBody, 200));
            await rejected;
            expect(closedBeforeResponse, 1);
            expect(closed, 1);
            expect(secure.calls.where((x) => x.$1 != 'read'), isEmpty);
            expect(secure.values['jellyfin_access_token'], isNot('new-token'));
            expect(secure.values['jellyfin_device_id'], 'fixed-device');
          },
          () => JellyfinClosingHttp((_) {
            sent.complete();
            return response.future;
          }, () => closed++),
        );
      },
    );
  }
  test('one pending login rejects a second attempt without opening a second transport', () async {
    final sent = Completer<void>(), response = Completer<http.Response>();
    var calls = 0, closed = 0;
    await http.runWithClient(
      () async {
        final (c, _) = await routinesHome('direct');
        await ready(c);
        final notifier = c.read(jellyfinConnectionProvider.notifier);
        final first = notifier.signIn(
          baseUrl: 'https://new.invalid',
          username: 'first',
          password: 'password',
        );
        await sent.future;
        final second = notifier.signIn(
          baseUrl: 'https://new.invalid',
          username: 'second',
          password: 'password',
        );
        final rejected = expectLater(
          second,
          throwsA(
            isA<DirectHomeAccessException>().having(
              (e) => e.code,
              'code',
              'busy',
            ),
          ),
        );
        response.complete(http.Response(jellyfinLoginBody, 200));
        await first;
        await rejected;
        expect(calls, 1);
        expect(closed, 1);
      },
      () => JellyfinClosingHttp((_) {
        calls++;
        if (!sent.isCompleted) sent.complete();
        return response.future;
      }, () => closed++),
    );
  });
  for (final status in [200, 401]) {
    test(
      'status$status keeps exact authentication protocol and owned transport cleanup',
      () async {
        var calls = 0, closed = 0;
        await http.runWithClient(
          () async {
            final (c, _) = await routinesHome('direct');
            await ready(c);
            secure.calls.clear();
            final notifier = c.read(jellyfinConnectionProvider.notifier);
            final future = notifier.signIn(
              baseUrl: 'https://new.invalid/prefix',
              username: 'name',
              password: 'synthetic-password',
            );
            if (status == 200) {
              await future;
              final config = c.read(jellyfinConnectionProvider).requireValue!;
              expect(config.baseUrl, 'https://new.invalid/prefix');
              expect(config.userId, 'new-user');
              expect(config.accessToken, 'new-token');
              expect(config.deviceId, 'fixed-device');
              await notifier.signOut();
              expect(await c.read(jellyfinConnectionProvider.future), isNull);
              expect(secure.values['jellyfin_device_id'], 'fixed-device');
            } else {
              await expectLater(future, throwsA(isA<Exception>()));
              expect(secure.calls.where((x) => x.$1 != 'read'), isEmpty);
            }
            expect(calls, 1);
            expect(closed, 1);
          },
          () => JellyfinClosingHttp((request) async {
            calls++;
            expect(request.method, 'POST');
            expect(
              request.url.toString(),
              'https://new.invalid/prefix/Users/AuthenticateByName',
            );
            expect(jsonDecode(request.body), {
              'Username': 'name',
              'Pw': 'synthetic-password',
            });
            expect(
              request.headers['X-Emby-Authorization'],
              contains('fixed-device'),
            );
            return http.Response(jellyfinLoginBody, status);
          }, () => closed++),
        );
      },
    );
  }
  test(
    'cold Core library graph has no HTTP factories or credential storage',
    () async {
      var clients = 0;
      await http.runWithClient(
        () async {
          final (c, _) = await routinesHome('core');
          final sub = c.listen(jellyfinLibrariesProvider, (_, _) {});
          addTearDown(sub.close);
          await c.read(jellyfinLibrariesProvider.future);
          await c.pump();
          expect(clients, 0);
          expect(secure.calls, isEmpty);
        },
        () {
          clients++;
          return MockClient((_) async => http.Response('{"Items":[]}', 200));
        },
      );
    },
  );
  for (final action in ['signIn', 'signOut']) {
    for (final stage in [
      'jellyfin_base_url',
      'jellyfin_access_token',
      'jellyfin_connection_pending_v1',
    ]) {
      test(
        '$action uncertain $stage effect retires the confirmed reader',
        () async {
          final transports = <int, int>{};
          var nextId = 0, posts = 0, reads = 0;
          await http.runWithClient(
            () async {
              final (c, _) = await routinesHome('direct');
              await ready(c);
              final reader = c.listen(jellyfinLibrariesProvider, (_, _) {});
              addTearDown(reader.close);
              await c.read(jellyfinLibrariesProvider.future);
              final oldClient = c.read(jellyfinClientProvider);
              expect(oldClient, isNotNull);
              expect(reads, 1);
              final priorTransport = nextId;
              var failed = false;
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .setMockMethodCallHandler(channel, (call) async {
                    final result = await secure.handle(call);
                    final key = (call.arguments as Map)['key'];
                    final method = stage == 'jellyfin_connection_pending_v1'
                        ? 'delete'
                        : action == 'signIn'
                        ? 'write'
                        : 'delete';
                    if (!failed && call.method == method && key == stage) {
                      failed = true;
                      throw PlatformException(
                        code: 'private-failure',
                        message: 'private-token-sentinel',
                      );
                    }
                    return result;
                  });
              final notifier = c.read(jellyfinConnectionProvider.notifier);
              await expectLater(
                action == 'signIn'
                    ? notifier.signIn(
                        baseUrl: 'https://new.invalid',
                        username: 'name',
                        password: 'password',
                      )
                    : notifier.signOut(),
                throwsA(
                  isA<DirectHomeAccessException>().having(
                    (e) => e.code,
                    'code',
                    'write_unconfirmed',
                  ),
                ),
              );
              await c.pump();
              expect(failed, isTrue);
              expect(c.read(jellyfinConnectionProvider).hasError, isTrue);
              expect(c.read(jellyfinClientProvider), isNull);
              expect(transports[priorTransport], 1);
              expect(
                c.read(jellyfinConnectionProvider).error.toString(),
                isNot(contains('private-token-sentinel')),
              );
              c.invalidate(jellyfinLibrariesProvider);
              await c.read(jellyfinLibrariesProvider.future);
              expect(reads, 1);
              expect(posts, action == 'signIn' ? 1 : 0);
              expect(secure.values['jellyfin_device_id'], 'fixed-device');
            },
            () {
              final id = ++nextId;
              return JellyfinClosingHttp((request) async {
                if (request.method == 'POST') {
                  posts++;
                  return http.Response(jellyfinLoginBody, 200);
                }
                reads++;
                return http.Response('{"Items":[]}', 200);
              }, () => transports[id] = (transports[id] ?? 0) + 1);
            },
          );
        },
      );
    }
  }
  test(
    'ordinary authentication rejection preserves the confirmed connection',
    () async {
      await http.runWithClient(() async {
        final (c, _) = await routinesHome('direct');
        await ready(c);
        final reader = c.listen(jellyfinClientProvider, (_, _) {});
        addTearDown(reader.close);
        final old = reader.read();
        expect(old, isNotNull);
        await expectLater(
          c
              .read(jellyfinConnectionProvider.notifier)
              .signIn(
                baseUrl: 'https://new.invalid',
                username: 'wrong',
                password: 'wrong',
              ),
          throwsA(isA<Exception>()),
        );
        await c.pump();
        expect(c.read(jellyfinConnectionProvider).hasError, isFalse);
        expect(reader.read(), same(old));
      }, () => MockClient((_) async => http.Response('{}', 401)));
    },
  );
}
