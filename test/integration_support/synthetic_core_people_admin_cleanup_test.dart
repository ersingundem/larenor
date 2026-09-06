import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/app_harness.dart';
import '../../integration_test/support/synthetic_core_account.dart';
import '../../integration_test/support/synthetic_core_people_admin_account.dart';
import '../../integration_test/support/synthetic_ha_server.dart';

void main() {
  for (final rejected in [false, true]) {
    testWidgets('actual people-admin harness cleanup preserves global zero guard: $rejected', (tester) async {
      late AppHarness app;
      await tester.runAsync(() async {
        final host = await SyntheticHaServer.start();
        final core = SyntheticCorePeopleAdminAccount();
        host.coreAccount = core;
        app = AppHarness.forSyntheticCleanup(host);
        final client = app.network.createHttpClient(null);
        try {
          Future<int> send(String method, String path, [Object? body]) async {
            final request = await client.openUrl(method, Uri.parse('${host.baseUrl}/api/v1$path'));
            request.headers.set('authorization', 'Bearer ${core.currentAccessToken}');
            if (body != null) {
              request.headers.contentType = ContentType.json;
              final bytes=utf8.encode(jsonEncode(body));request.contentLength=bytes.length;request.add(bytes);
            }
            final response=await request.close();await response.drain<void>();return response.statusCode;
          }
          expect(await send('POST','/auth/login',{'username':SyntheticCoreAccount.username,'password':SyntheticCoreAccount.password,'deviceName':'fixture'}),200);
          final base='/admin/home-people/${core.coreId}/${core.homeId}';
          expect(await send('POST',base,{'label':'Fixture person','order':0}),201);
          final record='$base/${core.firstId}', grant='$record/grants/${core.subjectId}';
          expect(await send('PUT',grant,{'expectedAclRevision':1,'permissions':{'read':true,'write':false}}),200);
          expect(await send('PUT',grant,{'expectedAclRevision':2,'permissions':{'read':false,'write':false}}),200);
          expect(await send('DELETE','$record?expectedRevision=1&expectedAclRevision=3'),204);
          expect(core.records,isEmpty);expect(core.mutations,['POST','PUT','PUT','DELETE']);
          if(rejected) {core.retireSession();expect(await send('GET','/admin/users'),401);}
          expect(core.rejectedRequests,rejected?1:0);expect(core.injectedAckLosses,0);
          expect(host.requests,0);expect(host.acceptedActions,isEmpty);expect(app.network.blocked,0);
        } finally {client.close(force:true);}
      });
      Object? failure;
      await tester.runAsync(()async {try{await app.close(tester);}catch(error){failure=error;}});
      expect(failure,rejected?isA<TestFailure>():isNull);
    });
  }
}
