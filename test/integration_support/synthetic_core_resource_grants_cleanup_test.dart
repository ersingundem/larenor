import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/app_harness.dart';
import '../../integration_test/support/synthetic_core_account.dart';
import '../../integration_test/support/synthetic_core_resource_grants.dart';
import '../../integration_test/support/synthetic_ha_server.dart';

void main() {
  for (final mode in ['injected', 'unexpected503', 'injectedThenUnauthorized']) {
    testWidgets('actual harness cleanup keeps strict rejection gate: $mode', (
      tester,
    ) async {
      late AppHarness app;
      late HttpClient client;
      await tester.runAsync(() async {
        final host = await SyntheticHaServer.start();
        final grants = SyntheticCoreResourceGrants();
        final core = SyntheticCoreAccount(grants: grants);
        host.coreAccount = core;
        app = AppHarness.forSyntheticCleanup(host);
        client = app.network.createHttpClient(null);
        Future<int> send(String method, String path, Object? body) async {
          final request = await client.openUrl(
            method,
            Uri.parse('${host.baseUrl}/api/v1$path'),
          );
          request.headers.set('authorization', 'Bearer ${core.currentAccessToken}');
          if (body != null) {
            request.headers.contentType = ContentType.json;
            request.write(jsonEncode(body));
          }
          final response = await request.close();
          await response.drain<void>();
          return response.statusCode;
        }

        expect(await send('POST', '/auth/login', {
          'username': SyntheticCoreAccount.username,
          'password': SyntheticCoreAccount.password,
          'deviceName': 'fixture',
        }), 200);
        if (mode == 'unexpected503') {
          grants.replyGate = Completer<void>();
        } else {
          grants.failNextPutReply = true;
        }
        final path = '/admin/home-resources/${core.coreId}/${core.homeId}/${'1' * 32}/grants';
        expect(await send('PUT', '$path/${'3' * 32}', {
          'expectedAclRevision': 1,
          'permissions': {'read': true, 'write': false},
        }), 503);
        expect(grants.putRequests, 1);
        expect(grants.grants['3' * 32], {'read': true, 'write': false});
        if (mode == 'injectedThenUnauthorized') {
          core.revokeGrantSession();
          expect(await send('GET', path, null), 401);
        }
        expect(core.injectedAckLosses, mode == 'unexpected503' ? 0 : 1);
        expect(core.rejectedRequests, mode == 'injected' ? 0 : 1);
        client.close(force: true);
      });
      // This is the same teardown as the ninth Android journey, including
      // its unchanged global rejectedRequests == 0 assertion.
      Object? failure;
      await tester.runAsync(() async {
        try {
          await app.close(tester);
        } catch (error) {
          failure = error;
        }
      });
      expect(failure, mode == 'injected' ? isNull : isA<TestFailure>());
    });
  }
  testWidgets('cleanup-only harness cannot mount the application', (tester) async {
    late AppHarness app;
    await tester.runAsync(() async {
      app = AppHarness.forSyntheticCleanup(await SyntheticHaServer.start());
    });
    await expectLater(app.mount(tester), throwsA(isA<StateError>()));
    await tester.runAsync(() => app.close(tester));
  });
}
