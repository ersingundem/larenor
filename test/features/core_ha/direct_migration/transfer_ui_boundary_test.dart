import 'dart:async';
import 'dart:ui' show ViewFocusEvent,ViewFocusState,ViewFocusDirection;
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import '../core_ha_ui_fixture.dart';
import '../../../core/home_scope_fixture.dart' show flush;
import 'transfer_ui_fixture.dart';

VoidCallback held(WidgetTester tester,String id)=>tester.widget<CupertinoButton>(find.descendant(of:find.byKey(ValueKey(id)),matching:find.byType(CupertinoButton))).onPressed!;

void main() {
  for(final loss in ['focus','loading','error']) {
    testWidgets('held Direct entry under window $loss opens no transfer route', (tester) async {
      final h=HaUiHarness(); h.source.value=HomeSource.directLocal;
      await h.mount(tester,pin:'1234'); await h.signIn();
      h.router(tester).go('/settings/home-source'); await flush(tester); await unlock(tester);
      await transferReveal(tester,find.byKey(const ValueKey('core-ha-transfer-entry')));
      final old=held(tester,'core-ha-transfer-entry');
      if(loss=='loading') { h.runtime(tester).invalidate(windowPolicySnapshotProvider); }
      else if(loss=='error') { h.window.addError(StateError('private-window')); }
      else { h.window.add(const WindowPolicySnapshot(supported:true,isResumed:true,hasWindowFocus:false,reason:WindowRestrictionReason.noFocus)); }
      if(loss!='loading') await flush(tester);
      old(); await flush(tester);
      expect(find.byType(CupertinoTextField),findsNothing);
      expect(h.adapterRequests,isEmpty);
    });
  }
  for(final pending in [false,true]) {
    for(final loss in ['native','window','background','source','logout','pin','root']) {
      testWidgets('$loss retires actual transfer ${pending?'late401':'held confirm'}', (tester) async {
        final h=TransferUiHarness(); await h.open(tester); await h.prepare(tester);
        final old=held(tester,'core-ha-transfer-confirm'), late=Completer<http.Response>();
        if(pending) {
          h.transferReply=(_)=>late.future;
          old(); await flush(tester);
          expect(h.transferRequests.where((r)=>r.url.path.endsWith('/confirm')).length,1);
        }
        switch(loss) {
          case 'native': tester.binding.handleViewFocusChanged(ViewFocusEvent(viewId:tester.view.viewId,state:ViewFocusState.unfocused,direction:ViewFocusDirection.undefined));
          case 'window': h.window.add(const WindowPolicySnapshot(supported:true,isResumed:true,hasWindowFocus:false,reason:WindowRestrictionReason.noFocus));
          case 'background': tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          case 'source': h.source.writeFails=true; await h.home(tester).choose(HomeSource.verifiedCore);
          case 'logout': await h.account.signOut();
          case 'pin': h.runtime(tester).invalidate(pinLockProvider);
          case 'root': unawaited(Navigator.of(tester.element(find.byKey(const ValueKey('core-ha-transfer'))),rootNavigator:true).push(CupertinoPageRoute<void>(builder:(_)=>const CupertinoPageScaffold(child:Text('Covered')))));
        }
        if(pending) late.complete(h.json({'error':{'code':'unauthorized'}},401));
        await flush(tester); old(); await flush(tester);
        expect(h.transferRequests.where((r)=>r.url.path.endsWith('/confirm')).length,pending?1:0);
        if(loss!='logout') expect(h.account.session,isNotNull);
        expect(find.byKey(const ValueKey('core-ha-transfer-success')),findsNothing);
        expect(find.byKey(const ValueKey('core-ha-transfer-confirm')),findsNothing);
      });
    }
  }
  testWidgets('actual PIN loss between secure URL and token starts no preview POST', (tester) async {
    final h=TransferUiHarness(); await h.open(tester);
    await transferPress(tester,'core-ha-transfer-entity-switch.synthetic');
    await transferPress(tester,'core-ha-transfer-target-${h.f['resource']['ref']['id']}');
    h.platform.afterRead=(key) async {
      if(key=='ha_base_url') h.runtime(tester).invalidate(pinLockProvider);
    };
    await transferPress(tester,'core-ha-transfer-preview');
    expect(h.platform.calls.where((c)=>c.$2=='ha_token'),isEmpty);
    expect(h.transferRequests,isEmpty);
  });
}
