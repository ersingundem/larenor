import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../../integration_test/support/synthetic_core_account.dart';
import '../../integration_test/support/synthetic_core_resource_grants.dart';
import '../../integration_test/support/synthetic_ha_server.dart';
class _ChangingCore extends SyntheticCoreAccount {
 _ChangingCore(SyntheticCoreResourceGrants grants):super(grants:grants);
 String actor='9'*32,role='admin';bool mustChange=false;
 @override String get userId=>actor;
 @override Map<String,Object?> get user=>{...super.user,'role':role,'mustChangePassword':mustChange};
}
void main(){
 for(final change in ['none','core','home','actor','role','logout','password']){
  test('streamed ACL body rechecks $change before any effect',()async{
   final host=await SyntheticHaServer.start(),grants=SyntheticCoreResourceGrants();
   final core=_ChangingCore(grants);host.coreAccount=core;final client=FixtureNetwork(host.port).createHttpClient(null);
   try{
    final login=await client.postUrl(Uri.parse('${host.baseUrl}/api/v1/auth/login'));login.headers.contentType=ContentType.json;
    login.write(jsonEncode({'username':SyntheticCoreAccount.username,'password':SyntheticCoreAccount.password,'deviceName':'fixture'}));final auth=await login.close();await auth.drain<void>();expect(auth.statusCode,200);
    final started=Completer<void>();grants.bodyStarted=started;
    final req=await client.openUrl('PUT',Uri.parse('${host.baseUrl}/api/v1/admin/home-resources/${core.coreId}/${core.homeId}/${'1'*32}/grants/${'3'*32}'));
    req.headers.contentType=ContentType.json;req.headers.set('authorization','Bearer ${core.currentAccessToken}');req.write('{"expectedAclRevision":1,');await req.flush();
    await started.future.timeout(const Duration(seconds:2));
    if(change=='core')core.coreId='c'*32;if(change=='home')core.homeId='d'*32;if(change=='actor')core.actor='3'*32;if(change=='role')core.role='member';if(change=='logout')core.revokeGrantSession();if(change=='password')core.mustChange=true;
    req.write('"permissions":{"read":true,"write":false}}');final res=await req.close();await res.drain<void>();
    expect(res.statusCode,switch(change){'none'=>200,'core'||'home'=>404,'actor'||'logout'=>401,_=>403});
    expect(grants.putRequests,change=='none'?1:0);expect(grants.grants.isEmpty,change!='none');expect(host.requests,0);expect(host.acceptedActions,isEmpty);
   }finally{grants.close();client.close(force:true);await host.close();}
  });
 }
}
