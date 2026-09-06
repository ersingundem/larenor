import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import '../../core/home_scope_fixture.dart' show flush;
import 'home_resource_admin_fixture.dart';

class GrantsHarness extends ResourceAdminHarness {
  final grants=<String,Map<String,bool>>{};
  final puts=<http.Request>[];
  Completer<http.Response>? pendingGrant;
  int userReads=0,grantReads=0,grantStatus=200;
  final users=[for(final id in ['2','3','9']) {'id':id*32,'username':'person_$id','role':id=='9'?'admin':'member','disabled':false,'mustChangePassword':false,'revision':1,'createdAt':'2026-09-06T00:00:00Z'}];
  GrantsHarness() {final f=jsonDecode(File('contracts/home-resource-grants.v1.json').readAsStringSync()) as Map;records[0]=Map<String,dynamic>.from(f['target'] as Map);}
  String get targetId=>records.first['ref']['id'] as String;
  @override Future<http.Response> handle(http.Request request) async {
    if(request.url.path.endsWith('/admin/users')) {userReads++;return json({'users':users});}
    if(request.url.path.contains('/grants')) {
      final row=records.first;
      if(request.method=='GET') {
        grantReads++;final ids=grants.keys.toList()..sort();
        return json({'aclRevision':row['aclRevision'],'grants':[for(final id in ids) {'subjectId':id,'target':row['ref'],'aclRevision':row['aclRevision'],'permissions':grants[id]}]});
      }
      expectSync(request.method,'PUT');puts.add(request);
      if(grantStatus!=200)return pendingGrant?.future??json({'error':{'code':grantStatus==409?'revision_conflict':'synthetic-private-detail'}},grantStatus);
      final body=jsonDecode(request.body) as Map,subject=request.url.pathSegments.last;
      expectSync(body.keys.toSet(),{'expectedAclRevision','permissions'});expectSync(body['expectedAclRevision'],row['aclRevision']);
      expectSync(users.any((user)=>user['id']==subject),isTrue);
      final desired=Map<String,bool>.from(body['permissions'] as Map),old=grants[subject]??{'read':false,'write':false};
      if(old['read']!=desired['read']||old['write']!=desired['write']) {row['aclRevision']=(row['aclRevision'] as int)+1;if(desired['read']==true){grants[subject]=desired;}else{grants.remove(subject);}}
      return pendingGrant?.future??json({'grant':{'subjectId':subject,'target':row['ref'],'aclRevision':row['aclRevision'],'permissions':desired}});
    }
    return super.handle(request);
  }
}
Future<void> openGrants(WidgetTester tester,GrantsHarness h) async {
 await openAdmin(tester,h,pin:'1234');await adminPress(tester,'home-resource-grants-${h.targetId}');
 expect(adminKey('home-resource-grants-screen'),findsOneWidget);
}
void main() {
 testWidgets('actual PIN metadata entry grants named user read-only by default, updates and revokes', (tester) async {
  final h=GrantsHarness();await openGrants(tester,h);
  expect(h.userReads,1);expect(h.grantReads,1);expect(h.puts,isEmpty);
  await adminPress(tester,'resource-grants-user-${'3'*32}');
  expect(find.byType(CupertinoTextField),findsNothing);expect(h.puts,isEmpty);
  await adminPress(tester,'resource-grants-save');expect(h.puts.length,1);expect(h.grants['3'*32],{'read':true,'write':false});
  await adminPress(tester,'resource-grants-user-${'3'*32}');await adminPress(tester,'resource-grants-readWrite');await adminPress(tester,'resource-grants-save');
  expect(h.grants['3'*32],{'read':true,'write':true});
  await adminPress(tester,'resource-grants-user-${'3'*32}');await adminPress(tester,'resource-grants-none');await adminPress(tester,'resource-grants-save');
  expect(h.puts.length,2);expect(adminKey('resource-grants-revoke-confirmation'),findsOneWidget);
  await adminPress(tester,'resource-grants-confirm-revoke');expect(h.puts.length,3);expect(h.grants,isEmpty);
  final reads=h.resourceReads;await adminPress(tester,'resource-grants-back');expect(h.resourceReads,greaterThan(reads));expect(adminKey('home-resource-admin'),findsOneWidget);expect(h.haReads,0);
 });
 testWidgets('cancel selection and revoke confirmation never writes',(tester) async {
  final h=GrantsHarness()..grants['3'*32]={'read':true,'write':true};await openGrants(tester,h);
  await adminPress(tester,'resource-grants-user-${'3'*32}');await adminPress(tester,'resource-grants-none');await adminPress(tester,'resource-grants-save');
  await adminPress(tester,'resource-grants-cancel');expect(h.puts,isEmpty);expect(h.grants['3'*32]!['write'],isTrue);
 });
 for(final status in [409,503]) {
  testWidgets('grant $status requires explicit refresh and never retries PUT',(tester) async {
   final h=GrantsHarness();await openGrants(tester,h);await adminPress(tester,'resource-grants-user-${'2'*32}');h.grantStatus=status;
   await adminPress(tester,'resource-grants-save');expect(h.puts.length,1);
   expect(adminKey('resource-grants-${status==409?'conflict':'uncertain'}'),findsOneWidget);expect(adminKey('resource-grants-user-${'2'*32}'),findsNothing);
   await adminPress(tester,'resource-grants-refresh');expect(h.puts.length,1);expect(h.grantReads,2);expect(find.text('synthetic-private-detail'),findsNothing);
  });
 }
}
