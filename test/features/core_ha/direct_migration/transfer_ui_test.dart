import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';
import '../core_ha_ui_fixture.dart';
import '../../../core/home_scope_fixture.dart' show flush;
import 'transfer_ui_fixture.dart';

void main() {
  testWidgets('actual Direct HomeSource PIN route offers an explicit transfer entry', (tester) async {
    final h = HaUiHarness(); h.source.value=HomeSource.directLocal;
    await h.mount(tester,pin:'1234'); await h.signIn();
    h.router(tester).go('/settings/home-source'); await flush(tester);
    expect(find.byType(CupertinoTextField), findsOneWidget);
    await tester.enterText(find.byType(CupertinoTextField),'1234');
    await tester.testTextInput.receiveAction(TextInputAction.done); await flush(tester);
    expect(find.byKey(const ValueKey('core-ha-transfer-entry')), findsOneWidget);
  });
  testWidgets('actual PIN and HomeSession preview cancel confirm create once and preserve Direct', (tester) async {
    final h=TransferUiHarness(); await h.open(tester);
    final baseline=h.haReads;
    expect(h.platform.calls.where((c)=>c.$2=='ha_token'),isEmpty);
    await h.prepare(tester);
    expect(h.transferRequests.map((r)=>r.method),['POST']);
    expect(find.text('synthetic-transfer-token'),findsNothing);
    expect(find.text('https://panel.invalid/private'),findsNothing);
    await transferPress(tester,'core-ha-transfer-cancel');
    expect(h.bound,isFalse); expect(h.transferRequests.map((r)=>r.method),['POST','DELETE']);
    await transferPress(tester,'core-ha-transfer-preview');
    await transferPress(tester,'core-ha-transfer-confirm');
    expect(find.byKey(const ValueKey('core-ha-transfer-success')),findsOneWidget);
    expect(h.bound,isTrue); expect(h.source.value,HomeSource.directLocal); expect(h.source.writes,0);
    expect(h.platform.values['ha_token'],'synthetic-transfer-token');
    expect(h.platform.calls.where((c)=>c.$2?.startsWith('ha_')==true).every((c)=>c.$1=='read'),isTrue);
    expect(h.transferRequests.where((r)=>r.url.path.endsWith('/confirm')).length,1);
    expect(h.haReads,baseline);
  });
}
