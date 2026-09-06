import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_people/presentation/home_people_widgets.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../../integration_test/support/core_people_admin_journey.dart';

void main(){
 testWidgets('people admin lazy control scroll uses vertical page, never horizontal editable field',(tester)async{
  tester.view.devicePixelRatio=1;tester.view.physicalSize=const Size(320,500);addTearDown(tester.view.reset);final text=TextEditingController(text:'long field '*80);var invoked=0;
  await tester.pumpWidget(CupertinoApp(localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,home:PeoplePage(key:const ValueKey('home-people-admin'),title:'Fixture',onBack:(){},slivers:[SliverToBoxAdapter(child:CupertinoTextField(controller:text)),SliverList.builder(itemCount:25,itemBuilder:(_,i)=>SizedBox(height:130,child:i==24?CupertinoButton(key:const ValueKey('lazy-control'),onPressed:()=>invoked++,child:const Text('Target')):Text('Row $i')))])));
  await tester.pump();final horizontal=tester.state<ScrollableState>(find.byWidgetPredicate((w)=>w is Scrollable&&(w.axisDirection==AxisDirection.left||w.axisDirection==AxisDirection.right)));final before=horizontal.position.pixels;expect(find.byKey(const ValueKey('lazy-control')),findsNothing);
  await tapPeopleAdminControl(tester,'lazy-control');expect(invoked,1);expect(horizontal.position.pixels,before);expect(tester.takeException(),isNull);await tester.pumpWidget(const SizedBox.shrink());text.dispose();
 });
}
