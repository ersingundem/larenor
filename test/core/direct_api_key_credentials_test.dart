import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// Pinned plugin's real channel boundary; no store/provider replacements.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_config.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_credentials_store.dart';
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';
import 'package:larenor/features/media/bazarr/data/bazarr_config.dart';
import 'package:larenor/features/media/bazarr/data/bazarr_credentials_store.dart';
import 'package:larenor/features/media/bazarr/providers/bazarr_providers.dart';
import 'package:larenor/features/media/prowlarr/data/prowlarr_config.dart';
import 'package:larenor/features/media/prowlarr/data/prowlarr_credentials_store.dart';
import 'package:larenor/features/media/prowlarr/providers/prowlarr_providers.dart';

import 'direct_home_boundary_test.dart' show SecurePlatform;
import 'direct_home_routines_test.dart' show routinesHome;

const apiKeyServices=['jellyseerr','bazarr','prowlarr'];
typedef CredentialHandle=({Future<Object?> Function() read,Future<void> Function({required String baseUrl,required String apiKey}) save,Future<void> Function() clear});
CredentialHandle apiKeyStore(ProviderContainer? c,String name) {
  switch(name) {
    case 'jellyseerr': final s=c==null?JellyseerrCredentialsStore():c.read(jellyseerrCredentialsStoreProvider);return(read:s.read,save:s.save,clear:s.clear);
    case 'bazarr': final s=c==null?BazarrCredentialsStore():c.read(bazarrCredentialsStoreProvider);return(read:s.read,save:s.save,clear:s.clear);
    case 'prowlarr': final s=c==null?ProwlarrCredentialsStore():c.read(prowlarrCredentialsStoreProvider);return(read:s.read,save:s.save,clear:s.clear);
    default: throw StateError('unknown fixture');
  }
}
String? configUrl(Object? config)=>switch(config) {JellyseerrConfig c=>c.baseUrl,BazarrConfig c=>c.baseUrl,ProwlarrConfig c=>c.baseUrl,null=>null,_=>throw StateError('unexpected config type')};
Future<Object?> apiKeyConnection(ProviderContainer c,String name)=>switch(name) {
 'jellyseerr'=>c.read(jellyseerrConnectionProvider.future),'bazarr'=>c.read(bazarrConnectionProvider.future),_=>c.read(prowlarrConnectionProvider.future),
};
ProviderSubscription<dynamic> holdApiKey(ProviderContainer c,String name)=>switch(name) {
 'jellyseerr'=>c.listen(jellyseerrConnectionProvider,(_,_){}),'bazarr'=>c.listen(bazarrConnectionProvider,(_,_){}),_=>c.listen(prowlarrConnectionProvider,(_,_){}),
};
class ApiKeyPlatform extends SecurePlatform {
  ApiKeyPlatform(){values.clear();for(final name in apiKeyServices){values['${name}_base_url']='https://old.invalid';values['${name}_api_key']='synthetic-old-key';}}
  Future<void> Function(MethodCall)? afterEffect;
  Object? invalidRead;
  @override
  Future<Object?> handle(MethodCall call) async {
    final result=await super.handle(call);await afterEffect?.call(call);
    if(call.method=='read' && invalidRead!=null)return invalidRead;
    return result;
  }
}
void main() {
 TestWidgetsFlutterBinding.ensureInitialized();late ApiKeyPlatform secure;late FlutterSecureStoragePlatform previous;
 setUp(() {
  secure=ApiKeyPlatform();previous=FlutterSecureStoragePlatform.instance;FlutterSecureStoragePlatform.instance=MethodChannelFlutterSecureStorage();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),secure.handle);
 });
 tearDown(() {
  FlutterSecureStoragePlatform.instance=previous;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),null);
 });
 for(final name in apiKeyServices) {
  for(final mode in ['core','pending','error']) {
   test('$name $mode actual connection rejects without secure-storage access',() async {
    final(c,_)=await routinesHome(mode);final sub=holdApiKey(c,name);addTearDown(sub.close);
    await expectLater(apiKeyConnection(c,name),throwsA(isA<DirectHomeAccessException>()));expect(secure.calls,isEmpty);
   });
  }
  for(final operation in ['read','save','clear']) {
   test('$name held Core store cannot $operation',() async {
    final(c,_)=await routinesHome('core');final s=apiKeyStore(c,name);
    final Future<Object?> result=switch(operation){'read'=>s.read(),'save'=>s.save(baseUrl:'https://new.invalid',apiKey:'synthetic-new'),_=>s.clear()};
    await expectLater(result,throwsA(isA<DirectHomeAccessException>()));expect(secure.calls,isEmpty);
   });
  }
  test('$name private pending marker prevents mixed tuple reads',() async {
   secure.values['${name}_base_url']='https://new.invalid';secure.values['${name}_connection_pending_v1']='1';
   await expectLater(apiKeyStore(null,name).read(),throwsA(isA<DirectHomeAccessException>().having((e)=>e.code,'code','pending_mutation')));
   expect(secure.calls,[('read','${name}_connection_pending_v1')]);
  });
  test('$name source loss during first field read never returns the old tuple',() async {
   final(c,home)=await routinesHome('direct');final sub=holdApiKey(c,name);addTearDown(sub.close);await apiKeyConnection(c,name);
   final s=apiKeyStore(c,name);secure.calls.clear();secure.afterEffect=(call) async {if(call.method=='read'&&(call.arguments as Map)['key']=='${name}_base_url')await home.choose(HomeSource.verifiedCore);};
   await expectLater(s.read(),throwsA(isA<DirectHomeAccessException>()));expect(secure.calls, isNot(contains(('read','${name}_api_key'))));
  });
  test('$name held store never revives after Direct Core Direct',() async {
   final(c,home)=await routinesHome('direct');final sub=holdApiKey(c,name);addTearDown(sub.close);await apiKeyConnection(c,name);final s=apiKeyStore(c,name);
   await home.choose(HomeSource.verifiedCore);await home.choose(HomeSource.directLocal);secure.calls.clear();
   await expectLater(s.save(baseUrl:'https://new.invalid',apiKey:'synthetic-new'),throwsA(isA<DirectHomeAccessException>()));expect(secure.calls,isEmpty);
  });
  test('$name wrong platform read type becomes a static storage error',() async {
   secure.invalidRead={'private':'synthetic-secret'};
   await expectLater(apiKeyStore(null,name).read(),throwsA(isA<DirectHomeAccessException>().having((e)=>e.code,'code','storage_failed')));
  });
  test('$name standalone tuple read replace clear remains compatible',() async {
   final s=apiKeyStore(null,name);expect(configUrl(await s.read()),'https://old.invalid');await s.save(baseUrl:'https://new.invalid',apiKey:'synthetic-new');expect(configUrl(await s.read()),'https://new.invalid');await s.clear();expect(await s.read(),isNull);
  });
  test('$name explicit Direct background read does not require active window',() async {
   final(c,home)=await routinesHome('direct');final sub=holdApiKey(c,name);addTearDown(sub.close);expect(home.interaction.active,isFalse);expect(configUrl(await apiKeyConnection(c,name)),'https://old.invalid');
  });
 }
}
