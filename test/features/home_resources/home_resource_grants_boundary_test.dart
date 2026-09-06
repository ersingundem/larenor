import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/settings/providers/settings_providers.dart';
import '../../core/home_scope_fixture.dart' show flush;
import 'home_resource_admin_fixture.dart';
import 'home_resource_admin_boundary_test.dart' show lose;
import 'home_resource_grants_ui_test.dart';
Future<void> grantLoss(WidgetTester tester, GrantsHarness h, String loss) async {
 if(loss=='route') {unawaited(Navigator.of(tester.element(adminKey('home-resource-grants-screen'))).push(CupertinoPageRoute<void>(builder:(_)=>const CupertinoPageScaffold(child:Text('Covered')))));await flush(tester);} else {await lose(tester,h,loss);}
}
VoidCallback callback(WidgetTester tester,String key)=>tester.widget<CupertinoButton>(adminKey(key)).onPressed!;
Future<void> select(WidgetTester tester,{bool revoke=false}) async {
 await adminPress(tester,'resource-grants-user-${'3'*32}');
 if(revoke){await adminPress(tester,'resource-grants-none');await adminPress(tester,'resource-grants-save');}
}
void main(){
 testWidgets('held Save cannot bypass the separate revoke confirmation',(tester)async{
  final h=GrantsHarness()..grants['3'*32]={'read':true,'write':true};await openGrants(tester,h);await select(tester);
  await adminPress(tester,'resource-grants-none');final save=callback(tester,'resource-grants-save');save();await flush(tester);
  expect(adminKey('resource-grants-revoke-confirmation'),findsOneWidget);save();await flush(tester);expect(h.puts,isEmpty);
  await adminPress(tester,'resource-grants-confirm-revoke');expect(h.puts.length,1);expect(h.grants,isEmpty);
 });
 testWidgets('held permission action cannot change a frozen revoke proposal',(tester)async{
  final h=GrantsHarness()..grants['3'*32]={'read':true,'write':true};await openGrants(tester,h);await select(tester);
  final read=callback(tester,'resource-grants-readOnly');await adminPress(tester,'resource-grants-none');await adminPress(tester,'resource-grants-save');read();await flush(tester);
  expect(h.puts,isEmpty);await adminPress(tester,'resource-grants-confirm-revoke');expect(h.puts.length,1);expect(h.grants,isEmpty);
 });

 for(final loss in ['window','native','background','interaction','route','dispose','source','logout','role','expiry']) {
  for(final revoke in [false,true]) {
   testWidgets('${revoke?'revoke':'save'} old grant callback on $loss never PUTs',(tester) async {
    final h=GrantsHarness()..grants['3'*32]={'read':true,'write':true};await openGrants(tester,h);await select(tester,revoke:revoke);
    final action=callback(tester,revoke?'resource-grants-confirm-revoke':'resource-grants-save');await grantLoss(tester,h,loss);action();await flush(tester);
    expect(h.puts,isEmpty);expect(adminKey('resource-grants-revoke-confirmation'),findsNothing);expect(h.haReads,0);expect(tester.takeException(),isNull);
   });
  }
 }
 for(final loss in ['window','background','source','role']) {
  testWidgets('pending grant $loss closes client and late401 cannot reject current auth',(tester) async {
   final h=GrantsHarness();await openGrants(tester,h);await select(tester);final session=h.account.session,closed=h.closed;
   final late=Completer<http.Response>();h.pendingGrant=late;await adminPress(tester,'resource-grants-save');expect(h.puts.length,1);
   await grantLoss(tester,h,loss);expect(h.closed,greaterThan(closed));late.complete(h.json({'error':{'code':'unauthorized'}},401));h.pendingGrant=null;await flush(tester);
   if(loss!='role') expect(h.account.session,same(session));else expect(h.account.session!.user.role.name,'member');
   expect(adminKey('resource-grants-saved'),findsNothing);expect(h.puts.length,1);
  });
 }
 for(final loss in ['pin','root']) {
  testWidgets('$loss preframe retires grant callback',(tester) async {
   final h=GrantsHarness();await openGrants(tester,h);await select(tester);final action=callback(tester,'resource-grants-save');
   if(loss=='pin'){final c=h.runtime(tester);c.invalidate(pinLockProvider);expect(c.read(pinLockProvider).isLoading,isTrue);}else{unawaited(Navigator.of(tester.element(adminKey('home-resource-grants-screen')),rootNavigator:true).push(CupertinoPageRoute<void>(builder:(_)=>const CupertinoPageScaffold(child:Text('Covered')))));}
   action();await flush(tester);expect(h.puts,isEmpty);expect(h.account.session,isNotNull);
  });
 }
 testWidgets('same Save callback cannot double dispatch or revive after successful PUT',(tester) async {
  final h=GrantsHarness();await openGrants(tester,h);await select(tester);final late=Completer<http.Response>();h.pendingGrant=late;final action=callback(tester,'resource-grants-save');
  action();action();await flush(tester);expect(h.puts.length,1);
  late.complete(h.json({'grant':{'subjectId':'3'*32,'target':h.records.first['ref'],'aclRevision':h.records.first['aclRevision'],'permissions':h.grants['3'*32]}}));h.pendingGrant=null;await flush(tester);
  action();await flush(tester);expect(h.puts.length,1);expect(adminKey('resource-grants-saved'),findsOneWidget);
 });
}
