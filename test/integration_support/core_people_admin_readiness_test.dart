import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_people/presentation/home_people_widgets.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../../integration_test/support/core_people_admin_journey.dart';

void main() {
  for(final wrapped in [false,true]) {
    testWidgets('admin control waits for delayed enabled native button (wrapped: $wrapped)',(tester)async{
      final enabled=ValueNotifier(false);var invoked=0;
      await tester.pumpWidget(CupertinoApp(localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,home:PeoplePage(key:const ValueKey('home-people-admin'),title:'Fixture',onBack:(){},slivers:[SliverToBoxAdapter(child:ValueListenableBuilder<bool>(valueListenable:enabled,builder:(_,value,_)=>wrapped?PeopleButton(key:const ValueKey('delayed'),label:'Target',onPressed:value?()=>invoked++:null):CupertinoButton(key:const ValueKey('delayed'),onPressed:value?()=>invoked++:null,child:const Text('Target'))))])));
      await tester.pump();
      final timer=Timer(const Duration(seconds:3),()=>enabled.value=true);
      try {await tapPeopleAdminControl(tester,'delayed');expect(invoked,1);}finally{timer.cancel();await tester.pumpWidget(const SizedBox.shrink());enabled.dispose();}
      expect(tester.takeException(),isNull);
    });
  }
  testWidgets('admin control waits until its actual route is current', (tester) async {
    final navigator=GlobalKey<NavigatorState>();var invoked=0;
    await tester.pumpWidget(CupertinoApp(navigatorKey:navigator,localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,home:PeoplePage(key:const ValueKey('home-people-admin'),title:'Fixture',onBack:(){},slivers:[SliverToBoxAdapter(child:PeopleButton(key:const ValueKey('covered'),label:'Target',onPressed:()=>invoked++))])));
    unawaited(navigator.currentState!.push<void>(PageRouteBuilder(opaque:false,pageBuilder:(_,_,_)=>const ColoredBox(color:CupertinoColors.white))));
    await tester.pump();await tester.pump(const Duration(milliseconds:400));
    final timer=Timer(const Duration(seconds:3),()=>navigator.currentState!.pop());
    try {await tapPeopleAdminControl(tester,'covered');expect(invoked,1);}finally{timer.cancel();await tester.pumpWidget(const SizedBox.shrink());}
    expect(tester.takeException(),isNull);
  });
}
