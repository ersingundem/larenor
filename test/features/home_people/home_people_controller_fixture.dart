import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/home_people/data/home_people_controller.dart';
import 'package:larenor/features/home_people/data/home_people_providers.dart';
import 'package:larenor/features/home_people/data/home_person_grants_controller.dart';
import 'package:larenor/features/home_people/domain/home_person_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'home_person_models_test.dart' show fixture, copy;

Future<void> settle(WidgetTester tester) async {
  for (var i=0;i<10;i++) { await tester.pump(const Duration(milliseconds:1)); }
}
http.Response jsonResponse(Object? data,[int status=200]) => status==204 ? http.Response('',204) : http.Response(jsonEncode(data),status,headers:{'content-type':'application/json'});
class PeopleStore implements ServerSessionPersistence {
  ServerSession? value;
  @override Future<ServerSession?> read() async => value;
  @override Future<void> write(ServerSession? value) async { this.value=value; }
}
class PeopleSource implements HomeSourcePersistence {
  HomeSource value=HomeSource.verifiedCore;
  @override Future<HomeSource> read() async => value;
  @override Future<void> write(HomeSource value) async { this.value=value; }
}
class PeopleAuth extends LarenorServerApi {
  PeopleAuth(this.h):super(endpoint:ServerEndpoint('https://synthetic.invalid'),client:MockClient((_)async=>jsonResponse(null,500)));
  final PeopleHarness h;
  Completer<ServerContext>? pendingContext;
  int refreshes=0;
  ServerSession fresh() => ServerSession(endpoint:endpoint,accessToken:'access-$refreshes',refreshToken:'refresh-$refreshes',expiresAt:h.now.add(const Duration(hours:1)),user:ServerUser(id:h.userId,username:'Fixture',role:h.role,mustChangePassword:h.mustChangePassword));
  @override Future<ServerSession> login({required String username,required String password,required String deviceName})async=>fresh();
  @override Future<ServerSession> refresh(String token)async {refreshes++;return fresh();}
  @override Future<ServerContext> context(String token)async=>pendingContext==null?h.context:pendingContext!.future;
  @override Future<ServerUser> me(String token)async=>fresh().user;
  @override Future<void> logout(ServerSession session)async{}
}
class PeopleHarness {
  final f=fixture();
  DateTime now=DateTime.utc(2026,9,6);
  late ServerContext context=ServerContext.fromJson(f['context']);
  String userId='f'*32;
  ServerRole role=ServerRole.admin;
  bool mustChangePassword=false,pin=true,route=true,throwsOwner=false;
  final store=PeopleStore(),source=PeopleSource(),interaction=AppInteractionController();
  late final auth=PeopleAuth(this);
  late final account=ServerAccountController(store:store,apiFactory:(_)=>auth,clock:()=>now);
  late final home=HomeSessionController(store:source,account:account);
  final requests=<http.Request>[];
  int transports=0,closes=0;
  String listStep='adminList',grantStep='grantsAfterRead',writeStep='updatePerson';
  Future<http.Response> Function(http.Request)? reply;
  late final owner=HomePeopleOwner(isCurrent:()=>throwsOwner?throw StateError('private'):pin&&route,interaction:interaction);
  late final container=makeContainer();
  HomePeopleController? list;
  HomePersonGrantsController? grants;
  late final HomePersonRecord target=HomePersonRecord.fromJson(f['beforeUpdate']['response']['person'],expectedContext:context);
  ProviderContainer makeContainer()=>ProviderContainer(overrides:[homeSessionControllerProvider.overrideWithValue(home),homePeopleClockProvider.overrideWithValue(()=>now),homePeopleApiFactoryProvider.overrideWithValue((endpoint){transports++;return LarenorServerApi(endpoint:endpoint,client:TrackedClient((request)async{requests.add(request);if(reply!=null)return reply!(request);if(request.url.path.endsWith('/users'))return jsonResponse({'users':[user()]});final step=request.method=='GET'?(request.url.path.endsWith('/grants')?grantStep:listStep):writeStep;return jsonResponse(f[step]['response'],f[step]['status'] as int);},()=>closes++));})]);
  Map<String,Object> user()=>{'id':f['subjectId'] as String,'username':'member','role':'member','disabled':false,'mustChangePassword':false,'revision':1,'createdAt':'2026-09-06T00:00:00.000Z'};
  Future<void> login() => account.signIn(baseUrl:'https://synthetic.invalid',username:'fixture',password:'synthetic',deviceName:'fixture');
  Future<void> mount(WidgetTester tester,{bool admin=true,bool acl=false,int pageSize=25,Key? key})async {
    await account.initialize();await home.initialize();await login();home.runtimeMounted(home.runtimeIdentity);
    await tester.pumpWidget(UncontrolledProviderScope(container:container,child:CupertinoApp(home:PeopleProbe(key:key,h:this,admin:admin,acl:acl,pageSize:pageSize))));await settle(tester);
    addTearDown(()async {await tester.pumpWidget(const SizedBox.shrink());container.dispose();owner.dispose();interaction.dispose();home.dispose();account.dispose();await settle(tester);});
  }
}
class TrackedClient extends MockClient {
  TrackedClient(super.fn,this.closed);
  final void Function() closed;
  @override void close(){closed();super.close();}
}
class PeopleProbe extends ConsumerStatefulWidget {
  const PeopleProbe({super.key,required this.h,this.admin=true,this.acl=false,this.pageSize=25});
  final PeopleHarness h;final bool admin,acl;final int pageSize;
  @override ConsumerState<PeopleProbe> createState()=>PeopleProbeState();
}
class PeopleProbeState extends ConsumerState<PeopleProbe> {
  @override Widget build(BuildContext context){
    final h=widget.h;
    if(widget.acl){final c=ref.watch(homePersonGrantsControllerProvider((owner:h.owner,target:h.target)));h.grants=c;WidgetsBinding.instance.addPostFrameCallback((_){if(mounted)c.setVisible(true);});}
    else {final c=ref.watch(homePeopleControllerProvider((owner:h.owner,adminManagement:widget.admin,pageSize:widget.pageSize)));h.list=c;WidgetsBinding.instance.addPostFrameCallback((_){if(mounted)c.setVisible(true);});}
    return const SizedBox();
  }
}
