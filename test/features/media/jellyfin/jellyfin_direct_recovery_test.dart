import 'dart:async';
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_home_screen.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_discovery.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_connect_screen.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/direct_home_boundary_test.dart' show SecurePlatform;
import '../../../core/direct_home_routines_test.dart' show routinesHome;
import '../../../core/direct_jellyfin_actions_test.dart' show jellyfinLoginBody;

class FakeJellyfinDiscovery extends JellyfinDiscoveryService {
  int starts=0,stops=0;
  @override Stream<List<DiscoveredJellyfinServer>> get servers => const Stream.empty();
  @override Future<void> start({bool Function()? isCurrent}) async {starts++;}
  @override Future<void> stop() async {stops++;}
}
Future<void> pumpJellyfinFrames(WidgetTester tester)async{for(var i=0;i<8;i++){await tester.pump(const Duration(milliseconds:100));}}
Future<void> tapJellyfinText(WidgetTester tester,String text)async{final f=find.text(text).first;await tester.ensureVisible(f);await tester.tap(f);await pumpJellyfinFrames(tester);}
Widget jellyfinHarness(ProviderContainer c,Widget home,{required FakeJellyfinDiscovery discovery,required void Function() factory,AppInteractionController? interaction,GlobalKey<NavigatorState>? navigator}) => UncontrolledProviderScope(container:c,child:ProviderScope(overrides:[jellyfinDiscoveryFactoryProvider.overrideWithValue((){factory();return discovery;})],child:CupertinoApp(navigatorKey:navigator,localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,builder:interaction==null?null:(_,child)=>AppInteractionScope(controller:interaction,child:child!),home:home)));
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();late SecurePlatform secure;late FlutterSecureStoragePlatform previous;
 const channel=MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
 setUp((){secure=SecurePlatform()..values['jellyfin_device_id']='fixed-device'..values['settings_pin']='2468';previous=FlutterSecureStoragePlatform.instance;FlutterSecureStoragePlatform.instance=MethodChannelFlutterSecureStorage();SharedPreferences.setMockInitialValues({});TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,secure.handle);});
 tearDown((){FlutterSecureStoragePlatform.instance=previous;TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,null);});
 for(final mode in ['core','pending','error']){
  testWidgets('$mode mounted connect has no discovery, credentials or interactive fields',(tester)async{
   final(c,_)=await routinesHome(mode);final discovery=FakeJellyfinDiscovery();var factories=0;
   try{
    await tester.pumpWidget(jellyfinHarness(c,const JellyfinConnectScreen(),discovery:discovery,factory:()=>factories++));await pumpJellyfinFrames(tester);
    expect(factories,0);expect(discovery.starts,0);expect(secure.calls,isEmpty);expect(find.byType(CupertinoTextFormFieldRow),findsNothing);
   }finally{await tester.pumpWidget(const SizedBox.shrink());c.dispose();await tester.pump(const Duration(seconds:5));}
  });
 }
 for(final action in ['view','clear','connect']){
  testWidgets('pending record is recoverable through actual PIN settings via $action',(tester)async{
   secure.values['jellyfin_connection_pending_v1']='1';final(c,_)=await routinesHome('direct');final discovery=FakeJellyfinDiscovery();var factories=0,posts=0;final interaction=AppInteractionController();addTearDown(interaction.dispose);
   tester.view.physicalSize=const Size(600,1000);tester.view.devicePixelRatio=1;addTearDown(tester.view.reset);
   await http.runWithClient(()async{
    try{
     await tester.pumpWidget(jellyfinHarness(c,const SettingsGateScreen(),discovery:discovery,factory:()=>factories++,interaction:interaction));await pumpJellyfinFrames(tester);
     await tester.enterText(find.byType(CupertinoTextField),'2468');await tapJellyfinText(tester,'Unlock');await tapJellyfinText(tester,'Integrations');await tapJellyfinText(tester,'Manage Integrations');await tapJellyfinText(tester,'Jellyfin');
     expect(find.byType(JellyfinConnectScreen),findsOneWidget);expect(find.byType(CupertinoTextFormFieldRow),findsNWidgets(3));expect(tester.widgetList<CupertinoTextFormFieldRow>(find.byType(CupertinoTextFormFieldRow)).map((f)=>f.controller!.text),everyElement(isEmpty));expect(factories,0);expect(discovery.starts,0);
     if(action=='clear'){await tapJellyfinText(tester,'Remove saved connection');expect(secure.values.containsKey('jellyfin_connection_pending_v1'),isFalse);expect(secure.values.containsKey('jellyfin_access_token'),isFalse);expect(secure.values['jellyfin_device_id'],'fixed-device');expect(find.text('Done'),findsOneWidget);}
     if(action=='connect'){await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(0),'https://new.invalid');await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(1),'new-name');await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(2),'new-password');await tapJellyfinText(tester,'Connect');expect(secure.values['jellyfin_access_token'],'new-token');expect(secure.values['jellyfin_device_id'],'fixed-device');expect(secure.values.containsKey('jellyfin_connection_pending_v1'),isFalse);expect(find.byType(JellyfinConnectScreen),findsNothing);expect(posts,1);}
     else{expect(posts,0);}expect(factories,0);expect(tester.takeException(),isNull);
    }finally{await tester.pumpWidget(const SizedBox.shrink());c.dispose();await tester.pump(const Duration(seconds:5));}
   },()=>MockClient((request)async{expect(request.url.host,'new.invalid');if(request.method=='POST'){posts++;return http.Response(jellyfinLoginBody,200);}return http.Response('{"Items":[]}',200);}));
  });
 }
 for(final mode in ['idle','background','route','ticker','native_focus','source','provider']) {
  testWidgets('old connect callback cannot return after $mode retirement',(tester) async {
   secure.values['jellyfin_connection_pending_v1']='1';final(c,home)=await routinesHome('direct');final discovery=FakeJellyfinDiscovery();final interaction=AppInteractionController();addTearDown(interaction.dispose);final ticker=ValueNotifier(true);addTearDown(ticker.dispose);final navigator=GlobalKey<NavigatorState>();var requests=0,factories=0;
   await http.runWithClient(() async {
    try {
     await tester.pumpWidget(jellyfinHarness(c,ValueListenableBuilder<bool>(valueListenable:ticker,builder:(_,enabled,child)=>TickerMode(enabled:enabled,child:child!),child:const JellyfinConnectScreen()),discovery:discovery,factory:()=>factories++,interaction:interaction,navigator:navigator));await pumpJellyfinFrames(tester);
     await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(0),'https://new.invalid');await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(1),'old-draft-user');await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(2),'old-draft-password');
     final old=tester.widget<CupertinoButton>(find.widgetWithText(CupertinoButton,'Connect')).onPressed!;
     if(mode=='idle'){interaction.setActive(false);await pumpJellyfinFrames(tester);interaction.setActive(true);}
     if(mode=='background'){for(final state in [AppLifecycleState.inactive,AppLifecycleState.hidden,AppLifecycleState.paused,AppLifecycleState.hidden,AppLifecycleState.inactive,AppLifecycleState.resumed]){tester.binding.handleAppLifecycleStateChanged(state);await pumpJellyfinFrames(tester);}}
     if(mode=='route'){unawaited(navigator.currentState!.push<void>(CupertinoPageRoute(builder:(_)=>const CupertinoPageScaffold(child:Text('Other route')))));await pumpJellyfinFrames(tester);old();await pumpJellyfinFrames(tester);expect(requests,0);navigator.currentState!.pop();}
     if(mode=='ticker'){ticker.value=false;await pumpJellyfinFrames(tester);ticker.value=true;}
     if(mode=='native_focus'){for(final state in [ViewFocusState.unfocused,ViewFocusState.focused]){tester.binding.handleViewFocusChanged(ViewFocusEvent(viewId:tester.view.viewId,state:state,direction:ViewFocusDirection.undefined));await pumpJellyfinFrames(tester);}}
     if(mode=='source'){await home.choose(HomeSource.verifiedCore);await home.choose(HomeSource.directLocal);}
     if(mode=='provider'){c.invalidate(jellyfinConnectionProvider);await pumpJellyfinFrames(tester);}
     await pumpJellyfinFrames(tester);
     if(!['source','provider'].contains(mode)){await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(0),'https://new.invalid');await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(1),'new-user');await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(2),'new-password');}
     secure.calls.clear();old();await pumpJellyfinFrames(tester);expect(requests,0);expect(secure.calls,isEmpty);expect(factories,0);expect(tester.takeException(),isNull);
    }finally{await tester.pumpWidget(const SizedBox.shrink());c.dispose();await tester.pump(const Duration(seconds:5));}
   },()=>MockClient((_)async{requests++;return http.Response(jellyfinLoginBody,200);}));
  });
 }
 for(final point in ['device','http','field']) {
  testWidgets('window permission loss during $point await prevents remaining login effects',(tester) async {
   secure.values['jellyfin_connection_pending_v1']='1';if(point=='device')secure.values.remove('jellyfin_device_id');final(c,_)=await routinesHome('direct');final discovery=FakeJellyfinDiscovery();final interaction=AppInteractionController();addTearDown(interaction.dispose);var requests=0;final response=Completer<http.Response>();
   TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call)async{final result=await secure.handle(call);final key=(call.arguments as Map)['key'];if(call.method=='write'&&(point=='device'&&key=='jellyfin_device_id'||point=='field'&&key=='jellyfin_base_url'))interaction.setActive(false);return result;});
   await http.runWithClient(() async {
    try{
     await tester.pumpWidget(jellyfinHarness(c,const JellyfinConnectScreen(),discovery:discovery,factory:(){},interaction:interaction));await pumpJellyfinFrames(tester);
     await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(0),'https://new.invalid');await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(1),'new-user');await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(2),'new-password');await tapJellyfinText(tester,'Connect');
     if(point=='http')interaction.setActive(false);response.complete(http.Response(jellyfinLoginBody,200));await pumpJellyfinFrames(tester);
     expect(requests,point=='device'?0:1);expect(secure.values['jellyfin_access_token'],'synthetic-secret');expect(secure.values['jellyfin_connection_pending_v1'],'1');expect(tester.takeException(),isNull);
    }finally{await tester.pumpWidget(const SizedBox.shrink());c.dispose();await tester.pump(const Duration(seconds:5));}
   },()=>MockClient((_){requests++;return response.future;}));
  });
 }
 testWidgets('successful standalone pushed login returns to its original route',(tester)async{
  secure.values['jellyfin_connection_pending_v1']='1';final(c,_)=await routinesHome('direct');final navigator=GlobalKey<NavigatorState>();final discovery=FakeJellyfinDiscovery();var requests=0;
  await http.runWithClient(()async{
   try{
    await tester.pumpWidget(jellyfinHarness(c,CupertinoPageScaffold(child:CupertinoButton(onPressed:()=>navigator.currentState!.push<void>(CupertinoPageRoute(builder:(_)=>const JellyfinConnectScreen())),child:const Text('Original route'))),discovery:discovery,factory:(){},navigator:navigator));await pumpJellyfinFrames(tester);await tapJellyfinText(tester,'Original route');expect(navigator.currentState!.canPop(),isTrue);
    await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(0),'https://new.invalid');await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(1),'new-user');await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(2),'new-password');await tapJellyfinText(tester,'Connect');expect(requests,1);expect(navigator.currentState!.canPop(),isFalse);expect(find.text('Original route'),findsOneWidget);expect(find.byType(JellyfinConnectScreen),findsNothing);expect(secure.values['jellyfin_device_id'],'fixed-device');expect(tester.takeException(),isNull);
   }finally{await tester.pumpWidget(const SizedBox.shrink());c.dispose();await tester.pump(const Duration(seconds:5));}
  },()=>MockClient((_)async{requests++;return http.Response(jellyfinLoginBody,200);}));
 });

 for(final action in ['signIn','signOut']) {
  testWidgets('connected $action uncertainty retires account and offers blank explicit recovery',(tester)async{
   final(c,_)=await routinesHome('direct');final discovery=FakeJellyfinDiscovery();var factories=0,posts=0,failed=false;
   await http.runWithClient(()async{
    try{
     await tester.pumpWidget(jellyfinHarness(c,action=='signIn'?const JellyfinConnectScreen():const JellyfinHomeScreen(),discovery:discovery,factory:()=>factories++));await pumpJellyfinFrames(tester);
     expect(c.read(jellyfinConnectionProvider).requireValue,isNotNull);
     TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call)async{final result=await secure.handle(call);if(!failed&&call.method==(action=='signIn'?'write':'delete')&&(call.arguments as Map)['key']=='jellyfin_access_token'){failed=true;throw PlatformException(code:'private-error',message:'private-storage-sentinel');}return result;});
     if(action=='signIn'){
      await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(0),'https://new.invalid');await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(1),'private-name');await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(2),'private-password');await tapJellyfinText(tester,'Connect');
     }else{final rejected=expectLater(c.read(jellyfinConnectionProvider.notifier).signOut(),throwsA(isA<DirectHomeAccessException>()));await pumpJellyfinFrames(tester);await rejected;}
     await pumpJellyfinFrames(tester);expect(c.read(jellyfinConnectionProvider).hasError,isTrue);expect(c.read(jellyfinClientProvider),isNull);expect(find.byType(CupertinoTextFormFieldRow),findsNWidgets(3));expect(tester.widgetList<CupertinoTextFormFieldRow>(find.byType(CupertinoTextFormFieldRow)).map((f)=>f.controller!.text),everyElement(isEmpty));expect(find.text('Remove saved connection'),findsOneWidget);
     final afterFailureFactories=factories;await tapJellyfinText(tester,'Remove saved connection');expect(secure.values.containsKey('jellyfin_connection_pending_v1'),isFalse);expect(secure.values['jellyfin_access_token'],isNull);expect(secure.values['jellyfin_device_id'],'fixed-device');expect(factories,afterFailureFactories);expect(posts,action=='signIn'?1:0);expect(find.textContaining('private-storage-sentinel'),findsNothing);expect(tester.takeException(),isNull);
    }finally{await tester.pumpWidget(const SizedBox.shrink());c.dispose();await tester.pump(const Duration(seconds:5));}
   },()=>MockClient((request)async{if(request.method=='POST'){posts++;return http.Response(jellyfinLoginBody,200);}return http.Response('{"Items":[]}',200);}));
  });
 }

}
