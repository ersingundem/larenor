import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';
import '../core_ha_ui_fixture.dart';
import '../../../core/home_scope_fixture.dart' show flush;

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
}
