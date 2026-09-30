import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/mini_plugins/data/server_mini_plugin_api.dart';

class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? value) async {}
}

void main() {
  final url = Platform.environment['LARENOR_MINI_PLUGIN_CORE_URL'];
  setUpAll(() => HttpOverrides.global = null);

  test(
    'actual Client runs signed packaged plugin through normal Core Wasmtime',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Mini plugin gate',
      );
      expect(account.failure, isNull);

      await account.withSession((transport, session) async {
        final api = ServerMiniPluginApi(
          transport,
          session.accessToken,
          session.context!,
        );
        await api.catalog();
        expect(await api.list(), isEmpty);

        final instance = await api.create('Resource count');
        expect(instance.running, isTrue);
        final snapshot = await api.render(instance);
        expect(snapshot.pluginId, instance.id);
        expect(snapshot.resourceCount, inInclusiveRange(0, 512));
        expect(
          snapshot.artifactSha256,
          '7bdd159c4e384d2413d04b0bbf6ee8b26c4ea179c089258269e44accee04a8bf',
        );
        expect(snapshot.fuelConsumed, inInclusiveRange(1, 50000));
        expect(snapshot.linearMemoryBytesObserved, 65536);

        final stopped = await api.stop(instance);
        expect(stopped.running, isFalse);
        expect((await api.list()).single.running, isFalse);
        await expectLater(
          api.render(stopped),
          throwsA(
            isA<LarenorServerException>().having(
              (error) => error.code,
              'code',
              'conflict',
            ),
          ),
        );
      });
    },
    skip: url == null ? 'Requires isolated normal Core runner' : false,
  );
}
