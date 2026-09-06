import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_people/presentation/home_people_screen.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'home_people_ui_fixture.dart';

Finder key(String value) => find.byKey(ValueKey(value));
Future<void> reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    final scrollable = find
        .descendant(
          of: find.byType(CustomScrollView).last,
          matching: find.byType(Scrollable),
        )
        .first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await flush(tester);
    await tester.scrollUntilVisible(
      target,
      400,
      scrollable: scrollable,
      maxScrolls: 80,
    );
  }
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await flush(tester);
}

Future<void> press(WidgetTester tester, String value) async {
  await reveal(tester, key(value));
  await tester.tap(key(value));
  await flush(tester);
}

Future<void> openPeople(
  WidgetTester tester,
  PeopleUiHarness h, {
  String? pin,
  String locale = 'en',
  double width = 600,
  double scale = 1,
}) async {
  await h.mount(tester, pin: pin, locale: locale, width: width, scale: scale);
  await h.signIn();
  await flush(tester);
  expect(h.peopleReads, 0);
  await press(tester, 'home-people-entry');
}

Future<void> openManagement(
  WidgetTester tester,
  PeopleUiHarness h, {
  String? pin,
}) async {
  await openPeople(tester, h, pin: pin);
  await press(tester, 'home-people-manage');
  if (pin != null) {
    expect(find.byType(SettingsGateScreen), findsOneWidget);
    expect(h.writes, isEmpty);
    await tester.enterText(find.byType(CupertinoTextField), pin);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await flush(tester);
  }
  expect(key('home-people-admin'), findsOneWidget);
}

void main() {
  testWidgets(
    'Core explicit entry reads member profiles without automatic home GET or HA',
    (tester) async {
      final h = PeopleUiHarness()..role = 'member';
      await openPeople(tester, h);
      expect(find.byType(HomePeopleScreen), findsOneWidget);
      expect(find.text('Deniz Öztürk'), findsOneWidget);
      expect(key('home-people-manage'), findsNothing);
      expect(h.peopleReads, 1);
      expect(h.haReads, 0);
    },
  );
  testWidgets(
    'actual PIN gate metadata create rename order and delete cancellation',
    (tester) async {
      final h = PeopleUiHarness();
      await openManagement(tester, h, pin: '1234');
      await press(tester, 'home-people-create');
      await tester.enterText(key('home-people-label'), 'New person');
      await tester.enterText(key('home-people-order'), '4');
      await press(tester, 'home-people-save');
      expect(key('home-people-saved'), findsOneWidget);
      expect(h.writes.single.method, 'POST');
      final id = h.people.last['ref']['id'] as String;
      await press(tester, 'home-people-edit-$id');
      await tester.enterText(key('home-people-label'), 'Renamed person');
      await tester.enterText(key('home-people-order'), '3');
      await press(tester, 'home-people-save');
      expect(h.writes.last.method, 'PATCH');
      expect(h.people.last['order'], 3);
      await press(tester, 'home-people-delete-$id');
      expect(key('home-people-delete-confirmation'), findsOneWidget);
      expect(find.text('Renamed person'), findsOneWidget);
      await press(tester, 'home-people-cancel-edit');
      expect(h.writes.length, 2);
      await press(tester, 'home-people-delete-$id');
      await press(tester, 'home-people-confirm-delete');
      expect(h.writes.last.method, 'DELETE');
      expect(key('home-people-deleted'), findsOneWidget);
      expect(h.haReads, 0);
    },
  );
  testWidgets(
    'separate ACL route reads users writes permission confirms revoke and returns to fresh list',
    (tester) async {
      final h = PeopleUiHarness();
      await openManagement(tester, h, pin: '1234');
      final reads = h.peopleReads,
          id = '1' * 32,
          subject = h.peopleContract['subjectId'] as String;
      await press(tester, 'home-people-grants-$id');
      expect(key('home-person-grants-screen'), findsOneWidget);
      expect(h.userReads, 1);
      expect(h.grantReads, 1);
      await press(tester, 'home-people-user-$subject');
      await press(tester, 'home-people-permission-readWrite');
      await press(tester, 'home-people-grant-save');
      expect(h.grants[subject], {'read': true, 'write': true});
      await press(tester, 'home-people-user-$subject');
      await press(tester, 'home-people-permission-none');
      await press(tester, 'home-people-grant-save');
      expect(key('home-people-revoke-confirmation'), findsOneWidget);
      await press(tester, 'home-people-grant-cancel');
      expect(h.writes.length, 1);
      await press(tester, 'home-people-user-$subject');
      await press(tester, 'home-people-permission-none');
      await press(tester, 'home-people-grant-save');
      await press(tester, 'home-people-confirm-revoke');
      expect(h.grants, isEmpty);
      expect(h.writes.length, 2);
      await press(tester, 'home-people-grants-back');
      expect(key('home-people-admin'), findsOneWidget);
      expect(h.peopleReads, reads + 1);
      expect(h.haReads, 0);
    },
  );
  testWidgets(
    'uncertain create is recovered with explicit GET and never repeated',
    (tester) async {
      final h = PeopleUiHarness();
      await openManagement(tester, h);
      h.uncertainWrite = true;
      await press(tester, 'home-people-create');
      await tester.enterText(key('home-people-label'), 'Committed unknown');
      await press(tester, 'home-people-save');
      expect(key('home-people-uncertain'), findsOneWidget);
      expect(h.writes.length, 1);
      await flush(tester);
      expect(h.writes.length, 1);
      h.uncertainWrite = false;
      await press(tester, 'home-people-refresh');
      expect(find.text('Committed unknown'), findsOneWidget);
      expect(h.writes.length, 1);
    },
  );
  testWidgets(
    'empty and failed reads offer an explicit refresh without writes',
    (tester) async {
      final h = PeopleUiHarness()..people.clear();
      await openPeople(tester, h);
      expect(key('home-people-empty'), findsOneWidget);
      h.failPeople = true;
      await press(tester, 'home-people-refresh');
      expect(key('home-people-error'), findsOneWidget);
      expect(h.writes, isEmpty);
      h.failPeople = false;
      await press(tester, 'home-people-refresh');
      expect(key('home-people-empty'), findsOneWidget);
    },
  );
}
