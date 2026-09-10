import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/ssh/ssh_security_store.dart';
import '../remote_profiles_test.dart' show profile;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final disk=<String,String>{}; final calls=<MethodCall>[];
  late FlutterSecureStoragePlatform previous;
  late SshSecurityStore store; bool current=true;
  Future<Object?> Function(MethodCall)? intercept;
  const password=SshCredential(SshCredentialKind.password,'private-password');
  const pin=SshHostPin('ssh-ed25519','SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
  setUp(() async {
    previous=FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance=MethodChannelFlutterSecureStorage();
    disk.clear(); calls.clear(); current=true; intercept=null; store=SshSecurityStore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),(c) async {
      calls.add(c); if(intercept!=null) return intercept!(c);
      final a=c.arguments as Map; final k=a['key'] as String;
      switch(c.method) {case 'read': return disk[k];case 'write':disk[k]=a['value'];return null;case 'delete':disk.remove(k);return null;default:throw StateError('unexpected');}
    });
    final profiles=RemoteProfilesStore();await profiles.replace(await profiles.read(isCurrent:()=>true),[profile()],isCurrent:()=>true);calls.clear();
  });
  tearDown(() {FlutterSecureStoragePlatform.instance=previous;TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),null);});
  test('actual secure password and key records are separate from profile JSON',() async {
    final before=disk[RemoteProfilesStore.storageKey];
    await store.saveCredential(profile(),password,isCurrent:()=>current);
    expect((await store.readCredential(profile(),isCurrent:()=>current))!.secret,password.secret);
    expect(disk[RemoteProfilesStore.storageKey],before);expect(before, isNot(contains(password.secret)));
    const key=SshCredential(SshCredentialKind.privateKey,'-----BEGIN OPENSSH PRIVATE KEY-----\nsynthetic\n-----END OPENSSH PRIVATE KEY-----',passphrase:'secret-phrase');
    await store.saveCredential(profile(),key,isCurrent:()=>current);
    final saved=await store.readCredential(profile(),isCurrent:()=>current);expect(saved!.kind,key.kind);expect(saved.passphrase,key.passphrase);expect(saved.toString(),isNot(contains('secret-phrase')));
    await store.forgetCredential(profile(),isCurrent:()=>current);expect(await store.readCredential(profile(),isCurrent:()=>current),isNull);
  });
  test('references bind exact profile and endpoint identity',() {
    expect(store.reference(profile()),isNot(store.reference(profile(host:'other.example'))));expect(store.reference(profile()),isNot(store.reference(profile(port:2222))));expect(store.reference(profile()),isNot(contains('nas.example')));
  });
  test('first trust persists while changed key is never replaced',() async {
    await store.trust(profile(),pin,isCurrent:()=>current);
    expect((await store.readPin(profile(),isCurrent:()=>current))!.fingerprint,pin.fingerprint);
    final before=Map.of(disk);
    await expectLater(store.trust(profile(),const SshHostPin('ssh-ed25519','SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'),isCurrent:()=>current),throwsA(isA<SshFailure>().having((e)=>e.code,'code','host_changed')));
    expect(disk,before);
  });
  test('retirement after actual profile read stops credential read',() async {
    intercept=(c) async {current=false;return disk[(c.arguments as Map)['key']];};
    await expectLater(store.readCredential(profile(),isCurrent:()=>current),throwsA(isA<SshFailure>()));
    expect(calls.length,1);expect((calls.single.arguments as Map)['key'],RemoteProfilesStore.storageKey);
  });
  test('deleted or edited profile cannot load old credentials',() async {
    await store.saveCredential(profile(),password,isCurrent:()=>current);
    final p=RemoteProfilesStore();await p.replace(await p.read(isCurrent:()=>true),[profile(host:'new.example')],isCurrent:()=>true);calls.clear();
    await expectLater(store.readCredential(profile(),isCurrent:()=>current),throwsA(isA<SshFailure>().having((e)=>e.code,'code','profile_changed')));
    expect(calls.length,1);
  });
  test('write after-effect error is static and never automatically replayed',() async {
    intercept=(c) async {final a=c.arguments as Map;if(c.method=='write'){disk[a['key']]=a['value'];throw PlatformException(code:'private-payload');}return disk[a['key']];};
    await expectLater(store.saveCredential(profile(),password,isCurrent:()=>current),throwsA(isA<SshFailure>().having((e)=>e.code,'code','storage_failed')));
    expect(calls.where((c)=>c.method=='write').length,1);
    intercept=null;expect((await store.readCredential(profile(),isCurrent:()=>current))!.secret,password.secret);
  });
  test('corrupt secret is not empty or automatically overwritten',() async {
    await store.saveCredential(profile(),password,isCurrent:()=>current);
    final key=disk.keys.singleWhere((k)=>k!=RemoteProfilesStore.storageKey);disk[key]=jsonEncode({'password':'bad'});
    await expectLater(store.readCredential(profile(),isCurrent:()=>current),throwsA(isA<SshFailure>()));
    expect(disk[key],jsonEncode({'password':'bad'}));
  });
  test('invalid secret and pin bounds perform no write',() async {
    for(final bad in [const SshCredential(SshCredentialKind.password,''),SshCredential(SshCredentialKind.password,'x'*4097),const SshCredential(SshCredentialKind.password,'secret',passphrase:'not-applicable')]) {
      await expectLater(store.saveCredential(profile(),bad,isCurrent:()=>current),throwsA(isA<SshFailure>()));
    }
    await expectLater(store.trust(profile(),const SshHostPin('bad\n','raw'),isCurrent:()=>current),throwsA(isA<SshFailure>()));
    expect(calls.where((c)=>c.method=='write'),isEmpty);
  });
}
