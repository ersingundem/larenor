import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/proxmox/data/proxmox_client.dart';
import 'package:larenor/features/proxmox/data/proxmox_credentials_store.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';

import 'direct_home_boundary_test.dart'
    show SecurePlatform, SourceStore, SessionStore;
import '../features/proxmox/proxmox_transport_security_test.dart'
    show authResponse, dataResponse;

const proxmoxMarker = 'proxmox_connection_pending_v1';
const proxmoxFields = {
  'proxmox_host': 'old.invalid',
  'proxmox_port': '8443',
  'proxmox_username': 'old-user',
  'proxmox_realm': 'pve',
  'proxmox_password': 'synthetic-old-password',
  'proxmox_allow_self_signed': 'false',
};
const proxmoxStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

class ProxmoxSource extends SourceStore {
  ProxmoxSource(super.value);
  bool fail = false;
  Completer<HomeSource>? pending;
  @override
  Future<HomeSource> read() async {
    if (fail) throw StateError('synthetic-private-source');
    return pending == null ? value : pending!.future;
  }
}

Future<(ProviderContainer, HomeSessionController)> proxmoxHome(
  String mode, {
  ProxmoxClientFactory? factory,
  ProxmoxConnection Function()? connection,
}) async {
  final source = ProxmoxSource(
    mode == 'core' ? HomeSource.verifiedCore : HomeSource.directLocal,
  );
  if (mode == 'pending') source.pending = Completer<HomeSource>();
  if (mode == 'error') source.fail = true;
  final account = ServerAccountController(store: SessionStore());
  final home = HomeSessionController(store: source, account: account);
  final initializing = home.initialize();
  if (mode != 'pending') await initializing;
  final c = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      homeSessionControllerProvider.overrideWithValue(home),
      if (connection != null)
        proxmoxConnectionProvider.overrideWith(connection),
      proxmoxClientFactoryProvider.overrideWithValue(
        factory ??
            (config, health) => ProxmoxClient(
              config: config,
              healthSession: health,
              httpClient: MockClient(
                (request) async => request.url.path.endsWith('/access/ticket')
                    ? authResponse()
                    : dataResponse([]),
              ),
            ),
      ),
    ],
  );
  addTearDown(() {
    c.dispose();
    home.dispose();
    account.dispose();
    source.pending?.complete(HomeSource.directLocal);
  });
  return (c, home);
}

Future<void> saveProxmox(ProxmoxCredentialsStore store) => store.save(
  host: 'new.invalid',
  port: 9443,
  username: 'new-user',
  realm: 'newrealm',
  password: 'synthetic-new-password',
  allowSelfSigned: true,
);
Future<void> signInProxmox(ProxmoxConnection connection) => connection.signIn(
  host: 'new.invalid',
  port: 9443,
  username: 'new-user',
  realm: 'newrealm',
  password: 'synthetic-new-password',
  allowSelfSigned: true,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SecurePlatform secure;
  late FlutterSecureStoragePlatform previous;
  setUp(() {
    secure = SecurePlatform()
      ..values.clear()
      ..values.addAll(proxmoxFields);
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    messenger.setMockMethodCallHandler(proxmoxStorageChannel, secure.handle);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(proxmoxStorageChannel, null);
    FlutterSecureStoragePlatform.instance = previous;
  });
  for (final mode in ['core', 'pending', 'error']) {
    test(
      '$mode actual client provider cannot read credentials or construct ticket transport',
      () async {
        var clients = 0;
        final (c, _) = await proxmoxHome(
          mode,
          factory: (config, health) {
            clients++;
            return ProxmoxClient(
              config: config,
              httpClient: MockClient((_) async => authResponse()),
            );
          },
        );
        final sub = c.listen(proxmoxClientProvider, (_, _) {});
        addTearDown(sub.close);
        await expectLater(
          c.read(proxmoxClientProvider.future),
          throwsA(isA<DirectHomeAccessException>()),
        );
        expect(secure.calls, isEmpty);
        expect(clients, 0);
      },
    );
    test('$mode held store read save clear remain closed', () async {
      final (c, _) = await proxmoxHome(mode);
      final store = c.read(proxmoxCredentialsStoreProvider);
      for (final operation in <Future<void> Function()>[
        () async {
          await store.read();
        },
        () => saveProxmox(store),
        store.clear,
      ]) {
        await expectLater(
          Future.sync(operation),
          throwsA(isA<DirectHomeAccessException>()),
        );
      }
      expect(secure.calls, isEmpty);
      expect(secure.values, proxmoxFields);
    });
  }
  test(
    'held store and logout stay retired after original source roundtrip',
    () async {
      final (c, home) = await proxmoxHome('direct');
      final sub = c.listen(proxmoxConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(proxmoxConnectionProvider.future);
      final store = c.read(proxmoxCredentialsStoreProvider);
      final logout = c.read(proxmoxConnectionProvider.notifier).signOut;
      await home.choose(HomeSource.verifiedCore);
      await home.choose(HomeSource.directLocal);
      home.runtimeMounted(home.runtimeIdentity);
      await c.pump();
      secure.calls.clear();
      for (final operation in <Future<void> Function()>[
        () async {
          await store.read();
        },
        () => saveProxmox(store),
        store.clear,
        logout,
      ]) {
        await expectLater(
          Future.sync(operation),
          throwsA(isA<DirectHomeAccessException>()),
        );
      }
      expect(secure.calls, isEmpty);
      expect(secure.values, proxmoxFields);
    },
  );
  for (final field in proxmoxFields.keys) {
    test('source change after read $field cannot publish config', () async {
      final (c, home) = await proxmoxHome('direct');
      var changed = false;
      messenger.setMockMethodCallHandler(proxmoxStorageChannel, (call) async {
        final result = await secure.handle(call);
        if (!changed &&
            call.method == 'read' &&
            (call.arguments as Map)['key'] == field) {
          changed = true;
          await home.choose(HomeSource.verifiedCore);
        }
        return result;
      });
      final store = c.read(proxmoxCredentialsStoreProvider);
      await expectLater(
        store.read(),
        throwsA(isA<DirectHomeAccessException>()),
      );
      expect(secure.calls.last.$2, field);
    });
    test(
      'partial $field platform effect requires explicit complete recovery',
      () async {
        var fail = true;
        messenger.setMockMethodCallHandler(proxmoxStorageChannel, (call) async {
          final result = await secure.handle(call);
          if (fail &&
              call.method == 'write' &&
              (call.arguments as Map)['key'] == field) {
            throw PlatformException(
              code: 'synthetic',
              message: 'synthetic-private-error',
            );
          }
          return result;
        });
        await expectLater(
          saveProxmox(ProxmoxCredentialsStore()),
          throwsA(isA<DirectHomeAccessException>()),
        );
        expect(secure.values[proxmoxMarker], '1');
        await expectLater(
          ProxmoxCredentialsStore().read(),
          throwsA(isA<DirectHomeAccessException>()),
        );
        fail = false;
        await saveProxmox(ProxmoxCredentialsStore());
        final saved = (await ProxmoxCredentialsStore().read())!;
        expect(saved.host, 'new.invalid');
        expect(saved.port, 9443);
        expect(saved.realm, 'newrealm');
        expect(saved.username, 'new-user');
        expect(saved.password, 'synthetic-new-password');
        expect(saved.allowSelfSigned, isTrue);
        expect(secure.values[proxmoxMarker], isNull);
      },
    );
  }
  for (final marker in ['1', '', 'false', 'synthetic-private']) {
    test(
      'non-null marker length ${marker.length} prevents all tuple reads and clients',
      () async {
        secure.values[proxmoxMarker] = marker;
        var clients = 0;
        final (c, _) = await proxmoxHome(
          'direct',
          factory: (config, health) {
            clients++;
            return ProxmoxClient(
              config: config,
              httpClient: MockClient((_) async => authResponse()),
            );
          },
        );
        final sub = c.listen(proxmoxClientProvider, (_, _) {});
        addTearDown(sub.close);
        await c
            .read(proxmoxConnectionProvider.future)
            .catchError((Object _) => null);
        await c.pump();
        await c
            .read(proxmoxClientProvider.future)
            .catchError((Object _) => null);
        expect(secure.calls.map((c) => c.$2), [proxmoxMarker]);
        expect(clients, 0);
        expect(c.read(proxmoxConnectionProvider).hasError, isTrue);
      },
    );
  }
  test('marker read error is static and never falls back to tuple', () async {
    messenger.setMockMethodCallHandler(proxmoxStorageChannel, (call) async {
      if (call.method == 'read' &&
          (call.arguments as Map)['key'] == proxmoxMarker) {
        throw PlatformException(
          code: 'synthetic',
          message: 'synthetic-private',
        );
      }
      return secure.handle(call);
    });
    await expectLater(
      ProxmoxCredentialsStore().read(),
      throwsA(isA<DirectHomeAccessException>()),
    );
    expect(secure.calls, isEmpty);
  });
  test('explicit clear removes only the six fields and marker without authentication', () async {
    secure.values[proxmoxMarker] = '1';
    secure.values['sonarr_connection_pending_v1'] = '1';
    await ProxmoxCredentialsStore().clear();
    expect(secure.values, {'sonarr_connection_pending_v1': '1'});
    expect(await ProxmoxCredentialsStore().read(), isNull);
  });
  for (final field in ['proxmox_allow_self_signed', 'proxmox_port']) {
    for (final invalid in <String?>[
      null,
      '',
      'garbage',
      '0',
      '65536',
      '08006',
      ' true ',
    ]) {
      test(
        'invalid $field value $invalid requires explicit recovery without transport',
        () async {
          if (invalid == null) {
            secure.values.remove(field);
          } else {
            secure.values[field] = invalid;
          }
          var clients = 0;
          final (c, _) = await proxmoxHome(
            'direct',
            factory: (config, health) {
              clients++;
              return ProxmoxClient(
                config: config,
                httpClient: MockClient((_) async => authResponse()),
              );
            },
          );
          final sub = c.listen(proxmoxClientProvider, (_, _) {});
          addTearDown(sub.close);
          await c
              .read(proxmoxConnectionProvider.future)
              .catchError((Object _) => null);
          await c.pump();
          await c
              .read(proxmoxClientProvider.future)
              .catchError((Object _) => null);
          expect(c.read(proxmoxConnectionProvider).hasError, isTrue);
          expect(clients, 0);
          expect(secure.calls.where((call) => call.$1 != 'read'), isEmpty);
        },
      );
    }
  }
  for (final tls in ['true', 'false']) {
    test(
      'explicit TLS $tls and valid port realm username semantics are unchanged',
      () async {
        secure.values['proxmox_allow_self_signed'] = tls;
        final saved = (await ProxmoxCredentialsStore().read())!;
        expect(saved.port, 8443);
        expect(saved.userWithRealm, 'old-user@pve');
        expect(saved.allowSelfSigned, tls == 'true');
        secure.values['proxmox_username'] = 'user@pam';
        expect(
          (await ProxmoxCredentialsStore().read())!.userWithRealm,
          'user@pam',
        );
      },
    );
  }
  for (final phase in ['ticket', 'nodes']) {
    test(
      'late $phase response after source roundtrip cannot save or publish a connection',
      () async {
        final started = Completer<void>(),
            response = Completer<http.Response>();
        var requests = 0;
        final (c, home) = await proxmoxHome(
          'direct',
          factory: (config, health) => ProxmoxClient(
            config: config,
            httpClient: MockClient((request) async {
              requests++;
              if (request.url.path.endsWith(
                phase == 'ticket' ? '/access/ticket' : '/nodes',
              )) {
                started.complete();
                return response.future;
              }
              return authResponse();
            }),
          ),
        );
        final sub = c.listen(proxmoxConnectionProvider, (_, _) {});
        addTearDown(sub.close);
        await c.read(proxmoxConnectionProvider.future);
        final failure = expectLater(
          signInProxmox(c.read(proxmoxConnectionProvider.notifier)),
          throwsA(isA<Exception>()),
        );
        await started.future;
        await home.choose(HomeSource.verifiedCore);
        await home.choose(HomeSource.directLocal);
        home.runtimeMounted(home.runtimeIdentity);
        await c.pump();
        secure.calls.clear();
        response.complete(
          phase == 'ticket' ? authResponse() : dataResponse([]),
        );
        await failure;
        expect(secure.calls.where((c) => c.$1 != 'read'), isEmpty);
        expect(secure.values, proxmoxFields);
        expect(requests, phase == 'ticket' ? 1 : 2);
      },
    );
  }
}
