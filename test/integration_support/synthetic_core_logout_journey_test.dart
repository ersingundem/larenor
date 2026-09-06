import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';

import '../../integration_test/support/app_harness.dart';
import '../../integration_test/support/synthetic_core_account.dart';
import '../../integration_test/support/synthetic_core_resource_grants.dart';
import '../../integration_test/support/synthetic_ha_server.dart';

void main() {
  testWidgets(
    'existing opt-in logout clears production store and passes actual strict harness close',
    (tester) async {
      await tester.runAsync(() async {
        final host = await SyntheticHaServer.start();
        final core = SyntheticCoreAccount(
          grants: SyntheticCoreResourceGrants(),
        );
        host.coreAccount = core;
        final app = AppHarness.forSyntheticCleanup(host);
        FlutterSecureStorage.setMockInitialValues({
          'settings_pin': AppHarness.pin,
          'ha_base_url': host.baseUrl,
          'ha_token': SyntheticHaServer.token,
        });
        final store = SecureServerSessionStore();
        var transports = 0;
        ServerAccountController controller() => ServerAccountController(
          store: store,
          apiFactory: (endpoint) {
            transports++;
            return LarenorServerApi(
              endpoint: endpoint,
              client: IOClient(app.network.createHttpClient(null)),
            );
          },
        );
        final account = controller();
        ServerAccountController? remounted;
        try {
          await account.signIn(
            baseUrl: host.baseUrl,
            username: SyntheticCoreAccount.username,
            password: SyntheticCoreAccount.password,
            deviceName: 'Synthetic logout tablet',
          );
          expect(account.context, isNotNull);
          expect((await store.read())?.context, account.context);
          final oldToken = core.currentAccessToken;
          await account.signOut();
          expect(account.session, isNull);
          expect(account.failure, isNull);
          expect(await SecureServerSessionStore().read(), isNull);
          expect(core.currentAccessToken == oldToken, isFalse);
          final before = (
            core.logins,
            core.meReads,
            core.contextReads,
            transports,
          );
          remounted = controller();
          await remounted.initialize();
          expect(remounted.initialized, isTrue);
          expect(remounted.session, isNull);
          expect((
            core.logins,
            core.meReads,
            core.contextReads,
            transports,
          ), before);
          const secure = FlutterSecureStorage();
          expect(await secure.read(key: 'settings_pin'), AppHarness.pin);
          expect(await secure.read(key: 'ha_token'), SyntheticHaServer.token);
          expect(host.requests, 0);
          expect(host.subscriptions, 0);
          expect(core.rejectedRequests, 0);
          expect(core.injectedAckLosses, 0);
          expect(app.network.blocked, 0);
        } finally {
          account.dispose();
          remounted?.dispose();
          await app.close(tester);
        }
      });
    },
  );

  test('fixture transport rejects non-fixture destinations before opening a socket', () async {
    final host = await SyntheticHaServer.start();
    final network = FixtureNetwork(host.port);
    final client = network.createHttpClient(null);
    try {
      expect(
        () => client.getUrl(Uri.parse('http://192.0.2.1/api/v1/auth/logout')),
        throwsA(isA<SocketException>()),
      );
      expect(network.blocked, 1);
      expect(host.requests, 0);
    } finally {
      client.close(force: true);
      await host.close();
    }
  });
}
