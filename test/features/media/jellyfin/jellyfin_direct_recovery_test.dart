import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
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
}
