import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/core_ha/data/core_ha_providers.dart';
import 'package:larenor/features/core_ha/direct_migration/transfer_screen.dart';
import 'package:larenor/features/core_ha/direct_migration/transfer_route.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import '../../../core/home_scope_fixture.dart' show flush;
import 'transfer_ui_fixture.dart';
import 'transfer_ui_boundary_test.dart' show held;

void main() {
  for(final pending in [false,true]) {
    testWidgets('actual retained transfer container A→B→A retires ${pending?'late401':'held confirm'}', (tester) async {
      final h=TransferUiHarness(); h.source.value=HomeSource.directLocal;
      SharedPreferences.setMockInitialValues({'dashboard_layout':jsonEncode(const DashboardLayout(rooms:[DashboardRoom(id:'room',name:'Room',entityIds:['switch.synthetic'])]).toJson())});
      FlutterSecureStorage.setMockInitialValues({'ha_base_url':'http://fixture.invalid:8123','ha_token':'synthetic-transfer-token'});
      await h.account.initialize(); await h.signIn();
      final home=HomeSessionController(store:h.source,account:h.account); await home.initialize(); home.runtimeMounted(home.runtimeIdentity);
      final interaction=AppInteractionController(),screenKey=GlobalKey();var callsB=0;
      ProviderContainer make(bool b)=>ProviderContainer(overrides:[
        homeSessionControllerProvider.overrideWithValue(home),
        coreHaClockProvider.overrideWithValue(()=>h.now),
        windowPolicySnapshotProvider.overrideWith((_) async* { yield const WindowPolicySnapshot(supported:false,isResumed:true,hasWindowFocus:true,reason:WindowRestrictionReason.unsupported); }),
        coreHaApiFactoryProvider.overrideWithValue((endpoint)=>LarenorServerApi(endpoint:endpoint,client:MockClient((r){if(b)callsB++;return h.handle(r);}),clock:()=>h.now)),
      ]);
      final a=make(false),b=make(true);
      Widget app(ProviderContainer c)=>UncontrolledProviderScope(container:c,child:AppInteractionScope(controller:interaction,child:CupertinoApp(localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,home:CoreHaTransferScreen(key:screenKey,gateCurrent:()=>true))));
      await tester.pumpWidget(app(a));await flush(tester);await h.prepare(tester);
      final old=held(tester,'core-ha-transfer-confirm'),element=screenKey.currentContext,state=tester.state(find.byType(CoreHaTransferRoute)),late=Completer<http.Response>();
      if(pending){h.transferReply=(_)=>late.future;old();await flush(tester);}
      await tester.pumpWidget(app(b));await flush(tester);
      expect(screenKey.currentContext,same(element));expect(tester.state(find.byType(CoreHaTransferRoute)),same(state));
      expect(a.read(homeSessionControllerProvider),same(b.read(homeSessionControllerProvider)));
      old();if(pending)late.complete(h.json({'error':{'code':'unauthorized'}},401));await flush(tester);
      expect(callsB,0);expect(h.account.session,isNotNull);expect(find.text('switch.synthetic'),findsNothing);
      await tester.pumpWidget(app(a));await flush(tester);old();await flush(tester);
      expect(h.transferRequests.where((r)=>r.url.path.endsWith('/confirm')).length,pending?1:0);
      expect(h.transferRequests.where((r)=>r.url.path.endsWith('/preview')).length,1);
      expect(find.byKey(const ValueKey('core-ha-transfer-confirm')),findsNothing);expect(tester.takeException(),isNull);
      await tester.pumpWidget(const SizedBox());await flush(tester);a.dispose();b.dispose();interaction.dispose();home.dispose();h.account.dispose();await h.window.close();
    });
  }
}
