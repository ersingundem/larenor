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
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';
import 'package:larenor/features/media/bazarr/providers/bazarr_providers.dart';
import 'package:larenor/features/media/prowlarr/providers/prowlarr_providers.dart';

import 'direct_api_key_credentials_test.dart';
import 'direct_home_routines_test.dart' show routinesHome;

typedef ApiKeySignIn=Future<void> Function({required String baseUrl,required String apiKey});
ApiKeySignIn apiKeySignIn(ProviderContainer c,String name)=>switch(name){
 'jellyseerr'=>c.read(jellyseerrConnectionProvider.notifier).signIn,'bazarr'=>c.read(bazarrConnectionProvider.notifier).signIn,_=>c.read(prowlarrConnectionProvider.notifier).signIn,
};
Future<void> Function() apiKeySignOut(ProviderContainer c,String name)=>switch(name){
 'jellyseerr'=>c.read(jellyseerrConnectionProvider.notifier).signOut,'bazarr'=>c.read(bazarrConnectionProvider.notifier).signOut,_=>c.read(prowlarrConnectionProvider.notifier).signOut,
};
Future<Object?> serviceRead(ProviderContainer c,String name)=>switch(name){
 'jellyseerr'=>c.read(jellyseerrMyRequestsProvider.future),'bazarr'=>c.read(bazarrMissingMoviesProvider.future),_=>c.read(prowlarrIndexersProvider.future),
};
ProviderSubscription<dynamic> holdServiceRead(ProviderContainer c,String name)=>switch(name){
 'jellyseerr'=>c.listen(jellyseerrMyRequestsProvider,(_,_){}),'bazarr'=>c.listen(bazarrMissingMoviesProvider,(_,_){}),_=>c.listen(prowlarrIndexersProvider,(_,_){}),
};
class ClosingHttp extends MockClient {
 ClosingHttp(super.handler,this.onClose);final void Function() onClose;
 @override void close(){onClose();super.close();}
}
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();late ApiKeyPlatform secure;late FlutterSecureStoragePlatform previous;
 setUp(() {secure=ApiKeyPlatform();previous=FlutterSecureStoragePlatform.instance;FlutterSecureStoragePlatform.instance=MethodChannelFlutterSecureStorage();TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),secure.handle);});
 tearDown(() {FlutterSecureStoragePlatform.instance=previous;TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),null);});
 for(final name in apiKeyServices){
  test('$name Core login rejects before constructing HTTP or touching store',() async {
   var clients=0,requests=0;
   await http.runWithClient(() async {
    final(c,_)=await routinesHome('core');final sub=holdApiKey(c,name);addTearDown(sub.close);
    try{await apiKeyConnection(c,name);}on DirectHomeAccessException{/* Expected cold scope failure. */}
    secure.calls.clear();
    await expectLater(apiKeySignIn(c,name)(baseUrl:'https://new.invalid',apiKey:'new'),throwsA(isA<DirectHomeAccessException>()));
    expect(clients,0);expect(requests,0);expect(secure.calls,isEmpty);
   },(){clients++;return MockClient((_) async {requests++;return http.Response('{}',200);});});
  });
  test('$name retained logout cannot reacquire credentials after a source round trip',() async {
   final(c,home)=await routinesHome('direct');final sub=holdApiKey(c,name);addTearDown(sub.close);await apiKeyConnection(c,name);final logout=apiKeySignOut(c,name);
   await home.choose(HomeSource.verifiedCore);await home.choose(HomeSource.directLocal);await c.pump();secure.calls.clear();
   await expectLater(logout(),throwsA(isA<DirectHomeAccessException>()));expect(secure.calls,isEmpty);
  });
  test('$name late old HTTP login cannot save in a new Direct runtime',() async {
   final response=Completer<http.Response>(),sent=Completer<void>();
   await http.runWithClient(() async {
    final(c,home)=await routinesHome('direct');final sub=holdApiKey(c,name);addTearDown(sub.close);await apiKeyConnection(c,name);
    final pending=apiKeySignIn(c,name)(baseUrl:'https://new.invalid',apiKey:'new');final rejected=expectLater(pending,throwsA(isA<DirectHomeAccessException>()));
    await sent.future;await home.choose(HomeSource.verifiedCore);await home.choose(HomeSource.directLocal);await c.pump();secure.calls.clear();
    response.complete(http.Response('{}',200));await rejected;
    expect(secure.calls.where((call)=>call.$1!='read'),isEmpty);expect(secure.values['${name}_api_key'],'synthetic-old-key');
   },()=>MockClient((_){sent.complete();return response.future;}));
  });
  for(final status in [200,401]){
   test('$name status$status preserves exact check endpoint and closes one-use transport',() async {
    var requests=0,closed=0;
    await http.runWithClient(() async {
     final(c,_)=await routinesHome('direct');final sub=holdApiKey(c,name);addTearDown(sub.close);await apiKeyConnection(c,name);secure.calls.clear();
     final login=apiKeySignIn(c,name)(baseUrl:'https://new.invalid',apiKey:'new');
     if(status==200){await login;expect(configUrl(await apiKeyConnection(c,name)),'https://new.invalid');}
     else {await expectLater(login,throwsA(isA<Exception>()));expect(secure.calls,isEmpty);}
     expect(requests,1);expect(closed,1);
    },()=>ClosingHttp((request) async {
     requests++;expect(request.method,'GET');expect(request.url.path,switch(name){'jellyseerr'=>'/api/v1/auth/me','bazarr'=>'/api/system/status',_=>'/api/v1/system/status'});expect(request.headers['X-Api-Key'],'new');return http.Response('{}',status);
    },()=>closed++));
   });
  }
  test('$name credential reload cannot expose a previously configured HTTP client',() async {
   final entered=Completer<void>(),release=Completer<void>();
   await http.runWithClient(() async {
    final(c,_)=await routinesHome('direct');final configSub=holdApiKey(c,name);addTearDown(configSub.close);await apiKeyConnection(c,name);final sub=holdServiceRead(c,name);addTearDown(sub.close);await serviceRead(c,name);
    secure.afterEffect=(call) async {if(call.method=='read'&&(call.arguments as Map)['key']=='${name}_connection_pending_v1'){if(!entered.isCompleted)entered.complete();await release.future;}};
    switch(name){case 'jellyseerr':c.invalidate(jellyseerrConnectionProvider);case 'bazarr':c.invalidate(bazarrConnectionProvider);case 'prowlarr':c.invalidate(prowlarrConnectionProvider);}
    final refreshing=apiKeyConnection(c,name);await entered.future;
    try {
      final client=switch(name){'jellyseerr'=>c.read(jellyseerrClientProvider),'bazarr'=>c.read(bazarrClientProvider),_=>c.read(prowlarrClientProvider)};
      expect(client,isNull);
    } finally {release.complete();await refreshing;}
   },()=>MockClient((_)async=>http.Response(name=='prowlarr'?'[]':'{"results":[],"data":[]}',200)));
  });
  test('$name cold Core service-read graph has zero credential reads and HTTP factories',() async {
   var clients=0,requests=0;
   await http.runWithClient(() async {
    final(c,_)=await routinesHome('core');final sub=holdServiceRead(c,name);addTearDown(sub.close);
    try{await serviceRead(c,name);}on DirectHomeAccessException{/* Allowed typed denial. */}
    await c.pump();await Future<void>.delayed(Duration.zero);
    expect(clients,0);expect(requests,0);expect(secure.calls,isEmpty);
   },(){clients++;return MockClient((_)async{requests++;return http.Response(name=='prowlarr'?'[]':'{"results":[],"data":[]}',200);});});
  });
  test('$name source revocation disposes old client and cannot refetch old configuration',() async {
   var requests=0,closed=0;
   await http.runWithClient(() async {
    final(c,home)=await routinesHome('direct');final configSub=holdApiKey(c,name);addTearDown(configSub.close);await apiKeyConnection(c,name);final sub=holdServiceRead(c,name);addTearDown(sub.close);await serviceRead(c,name);expect(requests,1);requests=0;
    await home.choose(HomeSource.verifiedCore);
    await expectLater(apiKeyConnection(c,name),throwsA(isA<DirectHomeAccessException>()));await c.pump();
    expect(requests,0);expect(closed,1);
   },()=>ClosingHttp((_)async{requests++;return http.Response(name=='prowlarr'?'[]':'{"results":[],"data":[]}',200);},()=>closed++));
  });
 }
}
