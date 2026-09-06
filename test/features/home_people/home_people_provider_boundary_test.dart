import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/home_people/data/home_people_providers.dart';
import 'package:larenor/features/home_people/data/home_people_controller.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'home_people_controller_fixture.dart';

void main(){
  for(final loss in ['false','throw','window']){
    testWidgets('owner $loss retirement never revives after recovery', (tester)async{
      final h=PeopleHarness();await h.mount(tester);expect(h.list!.entries,isNotEmpty);
      if(loss=='false')h.pin=false;if(loss=='throw')h.throwsOwner=true;if(loss=='window')h.interaction.setActive(false);
      h.owner.synchronize();expect(h.owner.isCurrent,isFalse);expect(h.list!.entries,isEmpty);
      h.pin=true;h.throwsOwner=false;h.interaction.setActive(true);h.owner.synchronize();await h.list!.refresh();expect(h.owner.isCurrent,isFalse);expect(h.requests.length,1);
    });
  }
  testWidgets('same mounted Consumer reparent with old container alive retires both owners', (tester)async{
    final h=PeopleHarness(),key=GlobalKey<PeopleProbeState>();await h.mount(tester,key:key);
    final state=key.currentState,old=h.list!,a=h.container;
    final subscription=a.listen(homePeopleControllerProvider((owner:h.owner,adminManagement:true,pageSize:25)),(_,_){});
    final b=h.makeContainer();
    await tester.pumpWidget(UncontrolledProviderScope(container:b,child:CupertinoApp(home:PeopleProbe(key:key,h:h))));await settle(tester);
    expect(key.currentState,same(state));expect(h.list,same(b.read(homePeopleControllerProvider((owner:h.owner,adminManagement:true,pageSize:25)))));
    expect(h.list,same(h.list));expect(h.list,same(h.list));
    await old.refresh();await h.list!.refresh();expect(h.requests.length,1);expect(old.entries,isEmpty);expect(h.list!.entries,isEmpty);expect(h.owner.isCurrent,isFalse);
    subscription.close();await tester.pumpWidget(const SizedBox.shrink());b.dispose();
  });
  testWidgets('autoDisposed provider closes pending transport and suppresses late401', (tester)async{
    final h=PeopleHarness(),pending=Completer<http.Response>();h.reply=(_)=>pending.future;await h.mount(tester);
    expect(h.requests.length,1);await tester.pumpWidget(const SizedBox.shrink());await settle(tester);expect(h.closes,1);
    pending.complete(jsonResponse({'error':{'code':'unauthorized'}},401));await settle(tester);expect(h.account.session,isNotNull);expect(h.store.value,isNotNull);
  });
  testWidgets('same-context auth refresh pending hides data then binds new pair without cancelling GET', (tester)async{
    final h=PeopleHarness();await h.mount(tester);final c=h.list!;h.now=h.now.add(const Duration(minutes:59,seconds:40));
    final pending=Completer<ServerContext>();h.auth.pendingContext=pending;
    final result=c.refresh();await settle(tester);expect(h.account.hasPendingContext,isTrue);expect(c.entries,isEmpty);expect(h.auth.refreshes,1);
    pending.complete(h.context);await result;await settle(tester);expect(h.account.failure,isNull);expect(c.entries.length,2);expect(h.requests.last.headers['authorization'],'Bearer access-1');
  });
  testWidgets('new user and home never publish old pending list', (tester)async{
    final h=PeopleHarness(),pending=Completer<http.Response>();h.reply=(_)=>pending.future;await h.mount(tester);
    h.userId='d'*32;h.context=ServerContext.fromJson(h.f['otherContextList']['response']['scope']);await h.login();h.home.runtimeMounted(h.home.runtimeIdentity);
    pending.complete(jsonResponse(h.f['adminList']['response']));await settle(tester);expect(h.list!.entries,isEmpty);expect(h.account.session!.user.id,'d'*32);expect(h.account.failure,isNull);
  });
  testWidgets('late dispatched metadata write cannot mutate after owner confirmation retires', (tester)async{
    final h=PeopleHarness();await h.mount(tester);final c=h.list!,pending=Completer<http.Response>();h.reply=(_)=>pending.future;bool current=true;
    final action=c.update(c.entries.first,label:'Ece Öztürk',order:0,isCurrent:()=>current);await settle(tester);expect(h.requests.where((r)=>r.method=='PATCH').length,1);
    current=false;pending.complete(jsonResponse(h.f['updatePerson']['response']));await action;expect(c.mutationOutcome,isNull);expect(c.entries.isEmpty,isTrue);
  });
}
