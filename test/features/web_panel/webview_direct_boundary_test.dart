import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/webview_tile.dart';
import 'package:larenor/features/web_panel/domain/web_panel_policy.dart';
import 'package:larenor/features/web_panel/presentation/web_panel_view.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../../core/direct_home_routines_test.dart' show routinesHome;
import '../dashboard/webview_tile_test.dart' show TestWebViewPlatform;

const privateTile=TileConfig(id:'saved-direct-panel',type:TileType.webview,x:0,y:0,width:2,height:2,url:'https://synthetic.invalid/private');
Widget app(ProviderContainer c,Widget child)=>UncontrolledProviderScope(container:c,child:CupertinoApp(localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,home:CupertinoPageScaffold(child:child)));
Future<void> frames(WidgetTester tester) async {for(var i=0;i<8;i++){await tester.pump();}}
void main(){
 late TestWebViewPlatform platform;WebViewPlatform? previous;
 setUp((){previous=WebViewPlatform.instance;platform=TestWebViewPlatform();WebViewPlatform.instance=platform;});
 tearDown((){WebViewPlatform.instance=previous??TestWebViewPlatform();});
 for(final mode in ['core','pending','error']){
  testWidgets('$mode retained Direct tile never constructs a native renderer',(tester)async{
   final(c,_)=await routinesHome(mode);
   try{await tester.pumpWidget(app(c,const WebviewTile(tile:privateTile)));await frames(tester);expect(platform.controllers,isEmpty);expect(find.byType(WebPanelView),findsNothing);expect(find.textContaining('synthetic.invalid'),findsNothing);expect(tester.takeException(),isNull);}
   finally{await tester.pumpWidget(const SizedBox.shrink());c.dispose();await frames(tester);}
  });
 }
 testWidgets('current Direct loads its exact configured website without an HA dependency',(tester)async{
  final(c,_)=await routinesHome('direct');
  try{await tester.pumpWidget(app(c,const WebviewTile(tile:privateTile)));await frames(tester);expect(platform.controllers,sized(1));expect(platform.controllers.single.requests.single.uri.toString(),privateTile.url);expect(platform.controllers.single.requests.single.headers,isEmpty);expect(tester.takeException(),isNull);}
  finally{await tester.pumpWidget(const SizedBox.shrink());c.dispose();await frames(tester);}
 });
 for(final stage in ['delegate','javascript']){
  testWidgets('$stage setup released after Direct retirement never loads the saved URL',(tester)async{
   final(c,home)=await routinesHome('direct');final gate=Completer<void>();
   if(stage=='delegate'){platform.nextDelegateGate=gate;}else{platform.nextJavaScriptGate=gate;}
   try{
    await tester.pumpWidget(app(c,const WebviewTile(tile:privateTile)));await frames(tester);expect(platform.controllers,sized(1));final old=platform.controllers.single;expect(old.requests,isEmpty);
    await home.choose(HomeSource.verifiedCore);gate.complete();await frames(tester);
    expect(old.requests,isEmpty);expect(find.byType(WebPanelView),findsNothing);expect(platform.controllers,sized(1));expect(tester.takeException(),isNull);
   }finally{if(!gate.isCompleted)gate.complete();await tester.pumpWidget(const SizedBox.shrink());c.dispose();await frames(tester);}
  });
 }
 testWidgets('captured navigation denies source loss before the next widget frame and never revives',(tester)async{
  final(c,home)=await routinesHome('direct');
  try{
   await tester.pumpWidget(app(c,const WebviewTile(tile:privateTile)));await frames(tester);final old=platform.controllers.single;final navigate=old.delegate.navigation;
   expect(await navigate(NavigationRequest(url:'https://synthetic.invalid/next',isMainFrame:true)),NavigationDecision.navigate);
   await home.choose(HomeSource.verifiedCore);
   expect(await navigate(NavigationRequest(url:'https://synthetic.invalid/next',isMainFrame:true)),NavigationDecision.prevent);
   await home.choose(HomeSource.directLocal);await frames(tester);
   expect(await navigate(NavigationRequest(url:'https://synthetic.invalid/next',isMainFrame:true)),NavigationDecision.prevent);expect(platform.controllers,sized(1));expect(find.byType(WebPanelView),findsNothing);
   // A new runtime creates a new wrapper, never recycles the retired capability.
   await tester.pumpWidget(app(c,const WebviewTile(key:ValueKey('fresh-runtime'),tile:privateTile)));await frames(tester);expect(platform.controllers,sized(2));expect(platform.controllers.last.requests.single.uri.toString(),privateTile.url);expect(tester.takeException(),isNull);
  }finally{await tester.pumpWidget(const SizedBox.shrink());c.dispose();await frames(tester);}
 });
 testWidgets('generic explicitly personal WebPanelView remains independent of Direct ownership',(tester)async{
  final(c,_)=await routinesHome('core');
  try{await tester.pumpWidget(app(c,WebPanelView(policy:WebPanelPolicy.fromUrl('https://personal.invalid/'))));await frames(tester);expect(platform.controllers,sized(1));expect(platform.controllers.single.requests.single.uri.host,'personal.invalid');expect(tester.takeException(),isNull);}
  finally{await tester.pumpWidget(const SizedBox.shrink());c.dispose();await frames(tester);}
 });
 testWidgets('retained widget cannot borrow a still-live Direct owner in a different Core scope',(tester)async{
  final(direct,_)=await routinesHome('direct');final(core,_)=await routinesHome('core');
  direct.listen(directHomeAccessProvider,(_,_){});final original=direct.read(directHomeAccessProvider);
  final tile=WebviewTile(key:GlobalKey(),tile:privateTile);
  try{
   await tester.pumpWidget(app(direct,tile));await frames(tester);final old=platform.controllers.single;final navigate=old.delegate.navigation;
   await tester.pumpWidget(app(core,tile));await frames(tester);
   expect(original.isCurrent,isTrue,reason:'the former runtime remains live independently of this widget');
   expect(find.byType(WebPanelView),findsNothing);expect(await navigate(NavigationRequest(url:'https://synthetic.invalid/next',isMainFrame:true)),NavigationDecision.prevent);expect(platform.controllers,sized(1));
   await tester.pumpWidget(app(direct,tile));await frames(tester);expect(find.byType(WebPanelView),findsNothing);expect(platform.controllers,sized(1));expect(tester.takeException(),isNull);
  }finally{await tester.pumpWidget(const SizedBox.shrink());direct.dispose();core.dispose();await frames(tester);}
 });
}
Matcher sized(int size)=>hasLength(size);
