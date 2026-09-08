import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import '../core_ha_ui_fixture.dart';
import '../../../core/home_scope_fixture.dart' show flush;
import 'transfer_credentials_test.dart' show TransferPlatform;

class TransferUiHarness extends HaUiHarness {
  final migration=jsonDecode(File('contracts/home-assistant-direct-migration.v1.json').readAsStringSync()) as Map<String,dynamic>;
  final platform=TransferPlatform();
  final transferRequests=<http.Request>[];
  Future<http.Response> Function(http.Request)? transferReply;
  Map<String,dynamic>? publicPreview;
  @override Future<http.Response> handle(http.Request r) async {
    if(!r.url.path.contains('/direct-migration/')) return super.handle(r);
    transferRequests.add(r);
    if(transferReply!=null) return transferReply!(r);
    if(r.method=='DELETE') return super.json(null,204);
    if(r.url.path.endsWith('/preview')) {
      final body=jsonDecode(r.body) as Map<String,dynamic>;
      final p=jsonDecode(jsonEncode(migration['preview']['response']['preview'])) as Map<String,dynamic>;
      p['requestId']=body['requestId'];
      (p['service'] as Map)..['name']=body['name']..['baseUrl']=body['baseUrl'];
      (p['binding'] as Map)['entityId']=body['entityId']; publicPreview=p;
      return super.json({'preview':p},201);
    }
    final p=publicPreview!;
    if(r.url.path.endsWith('/confirm')) bound=true;
    return super.json({'receipt':{
      'schemaVersion':1,'status':'committed',
      for(final key in ['requestId','ref','resourceRevision','aclRevision','service','binding']) key:p[key],
    }},r.method=='POST'?201:200);
  }
  Future<void> open(WidgetTester tester,{String locale='en',double width=600,double scale=1}) async {
    source.value=HomeSource.directLocal;
    const layout=DashboardLayout(rooms:[DashboardRoom(id:'local',name:'Local room',entityIds:['switch.synthetic','scene.evening','script.evening'])],tiles:[TileConfig(id:'panel',type:TileType.webview,x:0,y:0,width:1,height:1,url:'https://panel.invalid/private')]);
    await mount(tester,locale:locale,width:width,scale:scale,pin:'1234',preferences:{'dashboard_layout':jsonEncode(layout.toJson())});
    await signIn(); await flush(tester);
    final previous=FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance=MethodChannelFlutterSecureStorage();
    platform.values..['settings_pin']='1234'..['ha_base_url']='http://fixture.invalid:8123'..['ha_token']='synthetic-transfer-token';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),platform.handle);
    addTearDown(() {
      FlutterSecureStoragePlatform.instance=previous;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),null);
    });
    router(tester).go('/settings/home-source'); await flush(tester);
    await unlock(tester);
    await transferPress(tester,'core-ha-transfer-entry');
    expect(find.byKey(const ValueKey('core-ha-transfer')),findsNothing);
    await unlock(tester); await flush(tester);
    expect(find.byKey(const ValueKey('core-ha-transfer')),findsOneWidget);
  }
  Future<void> prepare(WidgetTester tester) async {
    await transferPress(tester,'core-ha-transfer-entity-switch.synthetic');
    await transferPress(tester,'core-ha-transfer-target-${f['resource']['ref']['id']}');
    await transferPress(tester,'core-ha-transfer-preview');
    expect(find.byKey(const ValueKey('core-ha-transfer-confirm')),findsOneWidget);
  }
}
Future<void> unlock(WidgetTester tester) async {
  expect(find.byType(CupertinoTextField),findsOneWidget);
  await tester.enterText(find.byType(CupertinoTextField),'1234');
  await tester.testTextInput.receiveAction(TextInputAction.done); await flush(tester);
}
Future<void> transferReveal(WidgetTester tester,Finder target) async {
  if(target.evaluate().isEmpty) {
    final candidates=find.byType(Scrollable).evaluate().where((e)=>e.widget is Scrollable && ((e.widget as Scrollable).axisDirection==AxisDirection.down));
    final scroll=find.byWidget(candidates.last.widget);
    await tester.scrollUntilVisible(target,300,scrollable:scroll,maxScrolls:30);
  }
  expect(target,findsOneWidget); await tester.ensureVisible(target); await flush(tester);
}
Future<void> transferPress(WidgetTester tester,String key) async {
  final target=find.byKey(ValueKey(key)); await transferReveal(tester,target);
  expect(target.hitTestable(),findsOneWidget); await tester.tap(target); await flush(tester);
}
