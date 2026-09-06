import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/keenetic/data/keenetic_api_exception.dart';
import 'package:larenor/features/keenetic/data/keenetic_config.dart';
import 'package:larenor/features/keenetic/providers/keenetic_providers.dart';

import 'direct_home_routines_test.dart' show routinesHome;
import 'direct_keenetic_boundary_test.dart' show keeneticReply;

const config = KeeneticConfig(
  baseUrl: 'https://router.invalid/prefix',
  username: 'synthetic-user',
  password: 'synthetic-password',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Core sign-in denies before the actual HTTP client factory', () async {
    var clients = 0, requests = 0;
    await http.runWithClient(
      () async {
        final (c, _) = await routinesHome('core');
        final sub = c.listen(keeneticConnectionProvider, (_, _) {});
        addTearDown(sub.close);
        try {
          await c.read(keeneticConnectionProvider.future);
        } catch (_) {}
        await expectLater(
          c
              .read(keeneticConnectionProvider.notifier)
              .signIn(
                baseUrl: config.baseUrl,
                username: config.username,
                password: config.password,
              ),
          throwsA(isA<DirectHomeAccessException>()),
        );
        expect(clients, 0);
        expect(requests, 0);
      },
      () {
        clients++;
        return MockClient((r) async {
          requests++;
          return keeneticReply(r);
        });
      },
    );
  });

  for (final initialCore in [false, true]) {
    test(
      'held factory rejects Core scope (initialCore=$initialCore) before constructing HTTP',
      () async {
        var clients = 0;
        await http.runWithClient(
          () async {
            final (c, home) = await routinesHome(
              initialCore ? 'core' : 'direct',
            );
            final factory = c.read(keeneticClientFactoryProvider);
            if (!initialCore) await home.choose(HomeSource.verifiedCore);
            expect(
              () => factory(config, null),
              throwsA(isA<DirectHomeAccessException>()),
            );
            expect(clients, 0);
          },
          () {
            clients++;
            return MockClient((r) async => keeneticReply(r));
          },
        );
      },
    );
  }

  test('handed client cannot read or command after source roundtrip', () async {
    var requests = 0;
    await http.runWithClient(
      () async {
        final (c, home) = await routinesHome('direct');
        final client = c.read(keeneticClientFactoryProvider)(config, null);
        addTearDown(client.dispose);
        await client.login();
        expect(client.isAuthenticated, isTrue);
        await home.choose(HomeSource.verifiedCore);
        await home.choose(HomeSource.directLocal);
        home.runtimeMounted(home.runtimeIdentity);
        final count = requests;
        expect(client.isAuthenticated, isFalse);
        await expectLater(
          client.getConnectedDevices(),
          throwsA(isA<KeeneticApiException>()),
        );
        await expectLater(
          client.setInterfaceUp('WifiMaster0/AccessPoint0', true),
          throwsA(isA<KeeneticApiException>()),
        );
        expect(requests, count);
      },
      () => MockClient((r) async {
        requests++;
        return keeneticReply(r);
      }),
    );
  });

  test(
    'retired reader late 401 cannot reauthenticate or publish data',
    () async {
      final entered = Completer<void>(), response = Completer<http.Response>();
      var requests = 0;
      await http.runWithClient(
        () async {
          final (c, home) = await routinesHome('direct');
          final client = c.read(keeneticClientFactoryProvider)(config, null);
          addTearDown(client.dispose);
          final read = client.getConnectedDevices();
          final rejected = expectLater(
            read,
            throwsA(isA<KeeneticApiException>()),
          );
          await entered.future;
          await home.choose(HomeSource.verifiedCore);
          response.complete(http.Response('', 401));
          await rejected;
          expect(requests, 1);
          expect(client.isAuthenticated, isFalse);
        },
        () => MockClient((r) async {
          requests++;
          if (!entered.isCompleted) {
            entered.complete();
            return response.future;
          }
          return keeneticReply(r);
        }),
      );
    },
  );

  test('retired challenge cannot send the password digest', () async {
    final entered = Completer<void>(), response = Completer<http.Response>();
    final requests = <http.Request>[];
    await http.runWithClient(
      () async {
        final (c, home) = await routinesHome('direct');
        final client = c.read(keeneticClientFactoryProvider)(config, null);
        addTearDown(client.dispose);
        final login = client.login();
        final rejected = expectLater(
          login,
          throwsA(isA<KeeneticApiException>()),
        );
        await entered.future;
        await home.choose(HomeSource.verifiedCore);
        response.complete(
          http.Response(
            '',
            401,
            headers: {
              'x-ndm-challenge': 'synthetic-challenge',
              'x-ndm-realm': 'synthetic-realm',
            },
          ),
        );
        await rejected;
        expect(requests, hasLength(1));
        expect(requests.single.method, 'GET');
        expect(client.isAuthenticated, isFalse);
      },
      () => MockClient((r) async {
        requests.add(r);
        if (!entered.isCompleted) {
          entered.complete();
          return response.future;
        }
        return keeneticReply(r);
      }),
    );
  });
}
