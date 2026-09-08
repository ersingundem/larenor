import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';

import '../core_ha_ui_fixture.dart';
import '../../../core/home_scope_fixture.dart' show flush;
import 'transfer_ui_fixture.dart';

void main() {
  testWidgets('empty Core choices are explicit and read no HA pair', (tester) async {
    final h=TransferUiHarness();
    h.response={'scope':h.f['context'],'entries':[],'snapshot':'a'*64,'nextAfter':null};
    await h.open(tester);
    expect(find.byKey(const ValueKey('core-ha-transfer-empty')),findsOneWidget);
    expect(h.platform.calls.where((c)=>c.$2=='ha_token'),isEmpty);
    expect(h.transferRequests,isEmpty);
  });
  testWidgets('actual transfer uncertain outcome offers GET recovery without token reread', (tester) async {
    final h=TransferUiHarness();await h.open(tester);await h.prepare(tester);
    h.transferReply=(_) async=>h.json({'error':{'code':'server_error'}},503);
    await transferPress(tester,'core-ha-transfer-confirm');
    expect(find.byKey(const ValueKey('core-ha-transfer-uncertain')),findsOneWidget);
    final reads=h.platform.calls.where((c)=>c.$2=='ha_token').length;
    final p=h.publicPreview!;
    h.transferReply=(r) async {expect(r.method,'GET');return h.json({'receipt':{'schemaVersion':1,'status':'committed',for(final key in ['requestId','ref','resourceRevision','aclRevision','service','binding']) key:p[key]}});};
    await transferPress(tester,'core-ha-transfer-recover');
    expect(find.byKey(const ValueKey('core-ha-transfer-success')),findsOneWidget);
    expect(h.platform.calls.where((c)=>c.$2=='ha_token').length,reads);
    expect(h.transferRequests.where((r)=>r.url.path.endsWith('/confirm')).length,1);
  });
  testWidgets('pending pair produces visible reconnect recovery without preview HTTP', (tester) async {
    final h=TransferUiHarness();await h.open(tester);
    h.platform.values['ha_connection_pending_v1']='1';
    await transferPress(tester,'core-ha-transfer-entity-switch.synthetic');
    await transferPress(tester,'core-ha-transfer-target-${h.f['resource']['ref']['id']}');
    await transferPress(tester,'core-ha-transfer-preview');
    expect(find.byKey(const ValueKey('core-ha-transfer-error')),findsOneWidget);
    expect(h.transferRequests,isEmpty);expect(h.platform.calls.where((c)=>c.$2=='ha_token'),isEmpty);
    expect(h.platform.values['ha_connection_pending_v1'],'1');
  });
  testWidgets(
    'actual Direct HomeSource PIN route offers an explicit transfer entry',
    (tester) async {
      final h = HaUiHarness();
      h.source.value = HomeSource.directLocal;
      await h.mount(tester, pin: '1234');
      await h.signIn();
      h.router(tester).go('/settings/home-source');
      await flush(tester);
      expect(find.byType(CupertinoTextField), findsOneWidget);
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await flush(tester);
      expect(
        find.byKey(const ValueKey('core-ha-transfer-entry')),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'actual PIN and HomeSession preview cancel confirm create once and preserve Direct',
    (tester) async {
      final h = TransferUiHarness();
      await h.open(tester);
      final baseline = h.haReads;
      expect(h.platform.calls.where((c) => c.$2 == 'ha_token'), isEmpty);
      await h.prepare(tester);
      expect(h.transferRequests.map((r) => r.method), ['POST']);
      expect(find.text('synthetic-transfer-token'), findsNothing);
      expect(find.text('https://panel.invalid/private'), findsNothing);
      await transferPress(tester, 'core-ha-transfer-cancel');
      expect(h.bound, isFalse);
      expect(h.transferRequests.map((r) => r.method), ['POST', 'DELETE']);
      await transferPress(tester, 'core-ha-transfer-preview');
      await transferPress(tester, 'core-ha-transfer-confirm');
      expect(
        find.byKey(const ValueKey('core-ha-transfer-success')),
        findsOneWidget,
      );
      expect(h.bound, isTrue);
      expect(h.source.value, HomeSource.directLocal);
      expect(h.source.writes, 0);
      expect(h.platform.values['ha_token'], 'synthetic-transfer-token');
      expect(
        h.platform.calls
            .where((c) => c.$2?.startsWith('ha_') == true)
            .every((c) => c.$1 == 'read'),
        isTrue,
      );
      expect(
        h.transferRequests.where((r) => r.url.path.endsWith('/confirm')).length,
        1,
      );
      expect(h.haReads, baseline);
    },
  );
}
