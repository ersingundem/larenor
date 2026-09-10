import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';

RemoteProfile profile({String host = 'nas.example', int port = 22,
  String id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}) => RemoteProfile(
  id: id, name: 'Ev sunucusu', protocol: RemoteProtocol.ssh,
  host: host, port: port, username: 'ersin');
Matcher failure(String code) => isA<RemoteProfilesFailure>().having((v) => v.code, 'code', code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final pair in <String, String>{'192.168.1.4':'192.168.1.4',
    ' NAS.Example. ':'nas.example','[2001:db8::1]':'2001:db8::1',
    '::1':'::1','xn--bcher-kva.example':'xn--bcher-kva.example'}.entries) {
    test('canonical address ${pair.key}', () => expect(normalizeRemoteHost(pair.key), pair.value));
  }
  for(final bad in ['https://host','user@host','host:22','host/path','a b','256.1.1.1',
    '192.168.001.1','-host.example','host..name','fe80::1%eth0','[::1]:22','', 'host\nname']) {
    test('reject malformed host $bad', () => expect(() => normalizeRemoteHost(bad), throwsA(failure('invalid_host'))));
  }
  test('protocol defaults and bracketed IPv6 address', () {
    expect(RemoteProtocol.values.map(remoteDefaultPort), [22,3389,5900]);
    expect(profile(host:'::1').address, '[::1]:22');
  });
  test('closed record never accepts secret or launch command keys', () {
    final value = profile().toJson();
    expect(RemoteProfile.fromJson(value).username, 'ersin');
    for(final key in ['password','privateKey','command','url']) {
      expect(() => RemoteProfile.fromJson({...value,key:'not-permitted'}), throwsA(failure('invalid_record')));
    }
  });
  test('ports and label bounds are enforced without coercion', () {
    final value = profile().toJson();
    for(final port in [0,65536,'22',true]) {
      expect(() => RemoteProfile.fromJson({...value,'port':port}), throwsA(failure('invalid_record')));
    }
    expect(() => profile(port:0).toJson(), throwsA(failure('invalid_record')));
    expect(() => RemoteProfile.fromJson({...value,'name':'x'*81}), throwsA(failure('invalid_record')));
  });
  group('actual secure platform store', () {
    final disk = <String,String>{};
    final calls = <String>[];
    Future<Object?> Function(MethodCall)? intercept;
    late RemoteProfilesStore store;
    setUp(() {
      disk.clear(); calls.clear(); intercept=null; store=RemoteProfilesStore();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (call) async {
          final a = Map<String,dynamic>.from(call.arguments as Map);
          calls.add('${call.method}:${a['key']}');
          if(intercept != null) return intercept!(call);
          if(call.method=='read') return disk[a['key']];
          if(call.method=='write') { disk[a['key']] = a['value']; return null; }
          throw StateError('unexpected method');
        });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), null));
    test('Core-free create edit delete and reopen preserve unrelated records', () async {
      disk['unrelated']='keep';
      final empty=await store.read(isCurrent:()=>true);
      final saved=await store.replace(empty,[profile()],isCurrent:()=>true);
      expect(saved.revision,1);expect(saved.profiles.single.address,'nas.example:22');
      final reopened=await RemoteProfilesStore().read(isCurrent:()=>true);
      final edited=await store.replace(reopened,[profile(host:'192.168.1.8')],isCurrent:()=>true);
      expect(edited.revision,2);
      await store.replace(edited,[],isCurrent:()=>true);
      expect((await store.read(isCurrent:()=>true)).profiles,isEmpty);
      expect(disk['unrelated'],'keep');
      expect(calls.every((c)=>c.endsWith(RemoteProfilesStore.storageKey)),isTrue);
    });
    test('unknown/corrupt/oversize data is never empty or overwritten', () async {
      for(final value in ['bad','x'*32769,jsonEncode({'version':1,'revision':0,'profiles':[],'extra':true})]) {
        disk[RemoteProfilesStore.storageKey]=value;
        await expectLater(store.read(isCurrent:()=>true),throwsA(failure('invalid_record')));
      }
      expect(calls.where((c)=>c.startsWith('write')),isEmpty);
    });
    test('stale snapshot cannot replace another editor save', () async {
      final a=await store.read(isCurrent:()=>true);
      await store.replace(a,[profile()],isCurrent:()=>true);
      await expectLater(store.replace(a,[],isCurrent:()=>true),throwsA(failure('conflict')));
      expect(calls.where((c)=>c.startsWith('write')).length,1);
    });
    test('queued retired action never reads or writes platform', () async {
      final release=Completer<void>();var active=true;
      final block=ConfigurationWrites.run(()=>release.future);
      final pending=store.read(isCurrent:()=>active);
      final assertion=expectLater(pending,throwsA(failure('retired')));
      active=false;release.complete();await block;await assertion;
      expect(calls,isEmpty);
    });
    test('retirement during platform read prevents publication and next write', () async {
      var active=true;
      intercept=(call) async {active=false;return null;};
      await expectLater(store.read(isCurrent:()=>active),throwsA(failure('retired')));
      expect(calls.length,1);
    });
    test('false and throwing owner deny before platform', () async {
      for(final owner in <bool Function()>[()=>false,()=>throw StateError('private')]) {
        await expectLater(store.read(isCurrent:owner),throwsA(failure('retired')));
      }
      expect(calls,isEmpty);
    });
    for(final after in [false,true]) {
      test('write failure ${after ? 'after':'before'} effect is honest and never retried', () async {
        final before=await store.read(isCurrent:()=>true);
        intercept=(call) async {
          final a=Map<String,dynamic>.from(call.arguments as Map);
          if(call.method=='read') return disk[a['key']];
          if(after) disk[a['key']]=a['value'];
          throw PlatformException(code:'private',message:'secret');
        };
        await expectLater(store.replace(before,[profile()],isCurrent:()=>true),throwsA(failure('write_unconfirmed')));
        expect(calls.where((c)=>c.startsWith('write')).length,1);
        intercept=null;
        expect((await store.read(isCurrent:()=>true)).profiles.length, after ? 1:0);
      });
    }
  });
}
