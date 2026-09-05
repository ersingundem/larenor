import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/media/arr/presentation/widgets/arr_connect_form.dart';
import 'package:larenor/features/media/data/media_api_exception.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/discovery/lan_discovery_section.dart';
import 'package:larenor/shared/discovery/service_signatures.dart';

import '../../../core/direct_home_routines_test.dart' show routinesHome;

Future<void> frames(WidgetTester tester) async { for(var i=0;i<4;i++) {await tester.pump(const Duration(milliseconds:100));} }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for(final transition in ['idle','background','hidden','route','source','callback','disposed']) {
    testWidgets('captured connect cannot outlive $transition even with a new draft', (tester) async {
      final (c,home)=await routinesHome('direct');
      final interaction=AppInteractionController(); addTearDown(interaction.dispose);
      final navigator=GlobalKey<NavigatorState>(); var calls=0;
      Future<void> first(String _,String _) async {calls++;}
      Future<void> second(String _,String _) async {calls+=10;}
      var connect=first; var visible=true;
      Widget tree()=>UncontrolledProviderScope(container:c,child:CupertinoApp(
        localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
        navigatorKey:navigator,
        builder:(_,child)=>AppInteractionScope(controller:interaction,child:child!),
        home:TickerMode(enabled:visible,child:ArrConnectForm(title:'Sonarr',urlHint:'',onConnect:connect)),
      ));
      await tester.pumpWidget(tree()); await frames(tester);
      Future<void> draft() async {
        final fields=find.byType(CupertinoTextFormFieldRow);
        await tester.enterText(fields.at(0),'https://synthetic.invalid'); await tester.enterText(fields.at(1),'synthetic-key');
      }
      await draft();
      final button=find.widgetWithText(CupertinoButton,'Connect');
      final old=tester.widget<CupertinoButton>(button).onPressed!;
      switch(transition) {
        case 'idle': interaction.setActive(false); await frames(tester); interaction.setActive(true); await frames(tester);
        case 'background': tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused); await frames(tester); tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); await frames(tester);
        case 'hidden': visible=false; await tester.pumpWidget(tree()); await frames(tester); visible=true; await tester.pumpWidget(tree()); await frames(tester);
        case 'route': navigator.currentState!.push(CupertinoPageRoute<void>(builder:(_)=>const CupertinoPageScaffold(child:Text('Covered')))); await frames(tester); navigator.currentState!.pop(); await frames(tester);
        case 'source': await home.choose(HomeSource.verifiedCore); await frames(tester); await home.choose(HomeSource.directLocal); await frames(tester);
        case 'callback': connect=second; await tester.pumpWidget(tree()); await frames(tester);
        case 'disposed': await tester.pumpWidget(const SizedBox.shrink()); await frames(tester);
      }
      if(find.byType(CupertinoTextFormFieldRow).evaluate().isNotEmpty) await draft();
      old(); await frames(tester);
      expect(calls,0);
      expect(tester.takeException(),isNull);
      await tester.pumpWidget(const SizedBox.shrink()); c.dispose(); await frames(tester);
    });
  }
  for(final failure in [false,true]) {
    testWidgets('late ${failure ? "failure" : "success"} after form removal has no widget update', (tester) async {
      final (c,_)=await routinesHome('direct'); final response=Completer<void>();
      await tester.pumpWidget(UncontrolledProviderScope(container:c,child:CupertinoApp(
        localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
        home:ArrConnectForm(title:'Sonarr',urlHint:'https://synthetic.invalid',onConnect:(_,_)=>response.future),
      )));
      await frames(tester); await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(1),'synthetic-key');
      await tester.tap(find.widgetWithText(CupertinoButton,'Connect')); await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      if(failure) {response.completeError(MediaApiException('synthetic-error'));} else {response.complete();}
      await frames(tester); expect(tester.takeException(),isNull); c.dispose();
    });
  }
  testWidgets('cold Core connect form never mounts discovery or dispatches a callback', (tester) async {
    final (c,_)=await routinesHome('core'); var calls=0;
    await tester.pumpWidget(UncontrolledProviderScope(container:c,child:CupertinoApp(
      localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
      home:ArrConnectForm(title:'Sonarr',urlHint:'',discoverySignature:ServiceSignatures.sonarr,onConnect:(_,_) async {calls++;}),
    ))); await frames(tester);
    expect(find.byType(LanDiscoverySection),findsNothing);
    expect(find.byType(CupertinoTextFormFieldRow),findsNothing); expect(calls,0);
    await tester.pumpWidget(const SizedBox.shrink());c.dispose();await frames(tester);
  });
}
