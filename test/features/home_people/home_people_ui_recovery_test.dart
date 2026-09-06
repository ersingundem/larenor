import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../../core/home_scope_fixture.dart' show flush;
import 'home_people_ui_boundary_test.dart' show held;
import 'home_people_ui_fixture.dart';
import 'home_people_ui_test.dart'
    show key, press, reveal, openPeople, openManagement;

void main() {
  testWidgets(
    'actual people paging uses frozen snapshot and full refresh remains after write',
    (tester) async {
      final h = PeopleUiHarness(), template = PeopleUiHarness().people.first;
      h.people.clear();
      for (var i = 1; i <= 30; i++) {
        final p = jsonDecode(jsonEncode(template)) as Map<String, dynamic>;
        p['ref']['id'] = i.toRadixString(16).padLeft(32, '0');
        p['label'] = 'Profile $i';
        p['order'] = 30 - i;
        h.people.add(p);
      }
      await openManagement(tester, h);
      expect(h.peopleReads, 2);
      final afterInitial = h.personRequests
          .where(
            (r) => r.method == 'GET' && r.url.path.contains('/home-people/'),
          )
          .last;
      expect(afterInitial.url.queryParameters, <String, String>{});
      await press(tester, 'home-people-load-more');
      expect(h.peopleReads, 3);
      final after = h.personRequests.last.url.queryParameters;
      expect(after, {
        'after': 25.toRadixString(16).padLeft(32, '0'),
        'expectedSnapshot': 'a' * 64,
      });
      expect(key('home-people-load-more'), findsNothing);
      final row30 = key(
        'home-people-row-${30.toRadixString(16).padLeft(32, '0')}',
      );
      await reveal(tester, row30);
      expect(find.text('Profile 30'), findsOneWidget);
      await press(
        tester,
        'home-people-edit-${30.toRadixString(16).padLeft(32, '0')}',
      );
      await tester.enterText(key('home-people-label'), 'Updated');
      await press(tester, 'home-people-save');
      expect(h.writes.single.method, 'PATCH');
      expect(key('home-people-load-more'), findsNothing);
      await press(tester, 'home-people-refresh');
      expect(h.personRequests.last.url.queryParameters, <String, String>{});
      await reveal(tester, key('home-people-load-more'));
      expect(key('home-people-load-more'), findsOneWidget);
      expect(h.haReads, 0);
    },
  );
  testWidgets(
    'actual ACL uncertain acknowledgement requires explicit GET and never repeats PUT',
    (tester) async {
      final h = PeopleUiHarness();
      await openManagement(tester, h);
      await press(tester, 'home-people-grants-${'1' * 32}');
      await press(tester, 'home-people-user-${h.peopleContract['subjectId']}');
      await press(tester, 'home-people-permission-readWrite');
      h.uncertainWrite = true;
      final old = held(tester, 'home-people-grant-save'), reads = h.grantReads;
      await press(tester, 'home-people-grant-save');
      expect(key('home-people-grant-uncertain'), findsOneWidget);
      expect(h.writes.length, 1);
      expect(h.grantReads, reads);
      expect(find.text('Member'), findsNothing);
      old();
      await flush(tester);
      expect(h.writes.length, 1);
      await press(tester, 'home-people-grant-refresh');
      expect(h.grantReads, reads + 1);
      expect(h.writes.length, 1);
      await press(tester, 'home-people-user-${h.peopleContract['subjectId']}');
      expect(key('home-people-permission-readWrite'), findsOneWidget);
      expect(h.haReads, 0);
    },
  );
  testWidgets(
    'active person HTTP401 still rejects the actual authenticated account',
    (tester) async {
      final h = PeopleUiHarness();
      await openPeople(tester, h);
      final late = Completer<http.Response>();
      h.pendingPeople = late;
      await press(tester, 'home-people-refresh');
      late.complete(
        h.json({
          'error': {'code': 'unauthorized'},
        }, 401),
      );
      h.pendingPeople = null;
      await flush(tester);
      expect(h.account.session, isNull);
      expect(h.store.value, isNull);
      expect(find.text('Deniz Öztürk'), findsNothing);
      expect(h.haReads, 0);
    },
  );
  testWidgets(
    'expired pending person read discards labels without repeating request or dropping account',
    (tester) async {
      final h = PeopleUiHarness();
      await openPeople(tester, h);
      final late = Completer<http.Response>();
      h.pendingPeople = late;
      await press(tester, 'home-people-refresh');
      h.now = h.account.session!.expiresAt;
      late.complete(
        h.json({
          'error': {'code': 'unauthorized'},
        }, 401),
      );
      h.pendingPeople = null;
      await flush(tester);
      expect(h.account.session, isNotNull);
      expect(find.text('Deniz Öztürk'), findsNothing);
      expect(h.peopleReads, 2);
      expect(h.haReads, 0);
    },
  );
}
