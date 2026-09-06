import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import '../../core/home_scope_fixture.dart' show flush;
import 'home_resource_admin_fixture.dart';
import 'home_resources_tablet_test.dart' show loadFonts;
void main() {
 for(final locale in ['en','tr']) {
  for(final width in [320.0,600.0,1280.0]) {
   testWidgets('admin $locale $width 2x keyboard and named 48px controls',(tester) async {
    await loadFonts(tester);final semantics=tester.ensureSemantics();addTearDown(semantics.dispose);
    final h=ResourceAdminHarness();await h.mount(tester,locale:locale,width:width,scale:2);await h.signIn();await flush(tester);
    await tester.scrollUntilVisible(adminKey('home-resources-manage'),300,scrollable:find.byType(Scrollable).first,maxScrolls:20);await adminPress(tester,'home-resources-manage');
    final create=adminKey('home-resource-admin-create');await tester.ensureVisible(create);await flush(tester);
    final l10n=AppLocalizations.of(tester.element(create));
    final node=tester.getSemantics(find.text(l10n.homeResourceAdminCreate));expect(node.label,l10n.homeResourceAdminCreate);expect(node.flagsCollection.isButton,isTrue);expect(node.rect.height,greaterThanOrEqualTo(48));
    Focus.of(tester.element(find.text(l10n.homeResourceAdminCreate))).requestFocus();await flush(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);await flush(tester);expect(adminKey('home-resource-label'),findsOneWidget);
    expect(find.byKey(ValueKey('home-resource-edit-${h.records.first['ref']['id']}')),findsNothing);
    for(final field in ['home-resource-label','home-resource-order']) {await tester.ensureVisible(adminKey(field));await flush(tester);expect(tester.getSize(adminKey(field)).height,greaterThanOrEqualTo(48));}
    final labelNode=tester.getSemantics(adminKey('home-resource-label'));expect(labelNode.label,contains(l10n.homeResourceAdminLabel));
    await tester.enterText(adminKey('home-resource-label'),'Unicode oda 🏠');await tester.sendKeyEvent(LogicalKeyboardKey.tab);await flush(tester);
    expect(tester.widget<EditableText>(find.descendant(of:adminKey('home-resource-order'),matching:find.byType(EditableText))).focusNode.hasFocus,isTrue);
    await tester.enterText(adminKey('home-resource-order'),'9');await tester.testTextInput.receiveAction(TextInputAction.done);await flush(tester);
    expect(h.mutations.length,1);expect(h.records.last['order'],9);
    final cancelId=h.records.last['ref']['id'];
    await tester.scrollUntilVisible(adminKey('home-resource-delete-$cancelId'),350,scrollable:find.byType(Scrollable).last,maxScrolls:20);
    await adminPress(tester,'home-resource-delete-$cancelId');await tester.ensureVisible(adminKey('home-resource-confirm-delete'));await flush(tester);
    expect(tester.getSize(adminKey('home-resource-confirm-delete')).height,greaterThanOrEqualTo(48));
    await adminPress(tester,'home-resource-cancel-edit');expect(h.mutations.length,1);expect(h.haReads,0);expect(tester.takeException(),isNull);
   });
  }
 }
}
