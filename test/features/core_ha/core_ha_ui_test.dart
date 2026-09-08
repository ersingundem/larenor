import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'core_ha_ui_fixture.dart';

Finder key(String value) => find.byKey(ValueKey(value));
Future<void> reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    final scrollable = find.descendant(of: find.byType(CustomScrollView).last, matching: find.byType(Scrollable)).first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await flush(tester);
    await tester.scrollUntilVisible(target, 400, scrollable: scrollable, maxScrolls: 30);
  }
  expect(target, findsOneWidget);
  await tester.ensureVisible(target); await flush(tester);
}
Future<void> press(WidgetTester tester, String value) async {
  await reveal(tester, key(value));
  expect(key(value).hitTestable(), findsOneWidget);
  await tester.tap(key(value)); await flush(tester);
}
Future<void> openSnapshot(WidgetTester tester, HaUiHarness h, {String locale = 'en', double width = 600, double scale = 1}) async {
  await h.mount(tester, locale: locale, width: width, scale: scale);
  await h.signIn(); await flush(tester);
  expect(h.adapterRequests, isEmpty);
  await reveal(tester, key('home-resource-${h.f['resource']['ref']['id']}'));
  expect(key('core-ha-open-${h.f['resource']['ref']['id']}'), findsOneWidget);
  await press(tester, 'core-ha-open-${h.f['resource']['ref']['id']}');
}
Future<void> openBinding(WidgetTester tester, HaUiHarness h, {String locale = 'en', double width = 600, double scale = 1}) async {
  await h.mount(tester, pin: '1234', locale: locale, width: width, scale: scale);
  await h.signIn(); await flush(tester);
  await press(tester, 'home-resources-manage');
  expect(find.byType(SettingsGateScreen), findsOneWidget);
  expect(h.adapterRequests, isEmpty);
  await tester.enterText(find.byType(CupertinoTextField), '1234');
  await tester.testTextInput.receiveAction(TextInputAction.done); await flush(tester);
  await reveal(tester, key('home-resource-edit-${h.f['resource']['ref']['id']}'));
  expect(key('core-ha-bind-${h.f['resource']['ref']['id']}'), findsOneWidget);
  await press(tester, 'core-ha-bind-${h.f['resource']['ref']['id']}');
}

void main() {
  testWidgets('actual Core home has no adapter request before selected member entry', (tester) async {
    final h = HaUiHarness()..role = 'member'; await openSnapshot(tester, h);
    expect(key('core-ha-snapshot'), findsOneWidget);
    expect(key('core-ha-state-off'), findsOneWidget);
    expect(key('core-ha-command'), findsNothing);
    expect(h.snapshotReads, 1); expect(h.haReads, 0);
  });
  testWidgets('stale expiry and offline refresh never keep the old switch value', (tester) async {
    final h = HaUiHarness(); await openSnapshot(tester, h);
    h.elapsed += const Duration(seconds: 6); await tester.pump(const Duration(seconds: 6));
    expect(key('core-ha-stale'), findsOneWidget); expect(key('core-ha-state-off'), findsNothing);
    h.snapshotStep = 'upstreamUnauthorized'; await press(tester, 'core-ha-refresh');
    expect(key('core-ha-error'), findsOneWidget); expect(key('core-ha-state-off'), findsNothing);
    expect(h.account.session, isNotNull); expect(h.haReads, 0);
  });
  testWidgets('actual PIN binding preview cancel and confirm are explicit and one-use', (tester) async {
    final h = HaUiHarness(); await openBinding(tester, h);
    expect(key('core-ha-binding'), findsOneWidget);
    await press(tester, 'core-ha-service-${h.f['preview']['body']['serviceId']}');
    await tester.enterText(key('core-ha-entity'), 'switch.synthetic');
    await press(tester, 'core-ha-preview');
    expect(key('core-ha-preview-details'), findsOneWidget);
    expect(h.adapterRequests.where((r) => r.url.path.endsWith('/binding-confirm')), isEmpty);
    await press(tester, 'core-ha-cancel');
    expect(key('core-ha-preview-details'), findsNothing);
    await press(tester, 'core-ha-preview');
    await press(tester, 'core-ha-confirm');
    expect(key('core-ha-saved'), findsOneWidget);
    expect(h.adapterRequests.where((r) => r.url.path.endsWith('/binding-confirm')).length, 1);
    expect(h.haReads, 0);
  });
  testWidgets('uncertain binding acknowledgement exposes explicit GET without repeating POST', (tester) async {
    final h = HaUiHarness(); await openBinding(tester, h);
    await press(tester, 'core-ha-service-${h.f['preview']['body']['serviceId']}');
    await tester.enterText(key('core-ha-entity'), 'switch.synthetic'); await press(tester, 'core-ha-preview');
    h.uncertainConfirm = true; await press(tester, 'core-ha-confirm');
    expect(key('core-ha-uncertain'), findsOneWidget);
    expect(key('core-ha-confirm'), findsNothing);
    await press(tester, 'core-ha-refresh'); expect(key('core-ha-existing'), findsOneWidget);
    expect(h.adapterRequests.where((r) => r.url.path.endsWith('/binding-confirm')).length, 1);
    expect(h.haReads, 0);
  });
  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets('$locale $width 2x binding native keyboard cancel and 48px semantics', (tester) async {
        final handle = tester.ensureSemantics();
        try {
        final h = HaUiHarness(); await openBinding(tester, h, locale: locale, width: width, scale: 2);
        await press(tester, 'core-ha-service-${h.f['preview']['body']['serviceId']}');
        await tester.enterText(key('core-ha-entity'), 'switch.synthetic');
        await press(tester, 'core-ha-preview');
        final native = find.descendant(of: key('core-ha-cancel'), matching: find.byType(CupertinoButton)).first;
        await reveal(tester, native);
        final button = tester.widget<CupertinoButton>(native);
        final rect = tester.getRect(native); expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(tester.getSemantics(native).getSemanticsData().flagsCollection.isButton, isTrue);
        // Traverse the real route, rather than directly invoking a callback.
        FocusManager.instance.primaryFocus?.unfocus();
        var reached = false;
        for (var i = 0; i < 14; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab); await tester.pump();
          final focus = FocusManager.instance.primaryFocus?.context;
          if (focus != null && (focus == tester.element(native) || (focus as Element).findAncestorWidgetOfExactType<CupertinoButton>() == button)) { reached = true; break; }
        }
        expect(reached, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter); await flush(tester);
        expect(key('core-ha-preview-details'), findsNothing);
        expect(h.adapterRequests.where((r) => r.url.path.endsWith('/binding-confirm')), isEmpty);
        expect(h.haReads, 0); expect(tester.takeException(), isNull);
        } finally { handle.dispose(); }
      });
    }
  }
}
