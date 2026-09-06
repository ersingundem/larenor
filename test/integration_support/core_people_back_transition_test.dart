import 'package:flutter/cupertino.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_scope/presentation/core_home_status_screen.dart';

import '../../integration_test/support/app_harness.dart' show tapVisible;
import '../../integration_test/support/core_people_journey.dart';
import '../../integration_test/support/single_element_ready.dart';
import '../features/home_people/home_people_ui_fixture.dart';
import '../features/home_people/home_people_ui_test.dart'
    show key, openPeople, press;

void main() {
  for (final dilation in [1.0, 4.0]) {
    testWidgets(
      'people journey awaits actual popped route disposal at dilation $dilation',
      (tester) async {
        final originalDilation = timeDilation;
        try {
          final h = PeopleUiHarness()..role = 'member';
          await openPeople(tester, h);
          expect(h.peopleReads, 1);
          h.people.clear();
          await press(tester, 'home-people-refresh');
          expect(key('home-people-empty'), findsOneWidget);
          expect(h.peopleReads, 2);
          final peopleRoute = ModalRoute.of(
            tester.element(key('home-people-list')),
          )!;
          expect(peopleRoute.isCurrent, isTrue);
          timeDilation = dilation;

          // The real back button and the journey's one-tap/350ms helper.
          await tapVisible(tester, key('home-people-back'));
          expect(peopleRoute.isCurrent, isFalse);
          expect(
            singleElementReady(
              find.byType(CoreHomeStatusScreen),
              (element) =>
                  ModalRoute.of(element)?.isCurrent == true &&
                  TickerMode.valuesOf(element).enabled,
            ),
            isTrue,
          );
          if (dilation > 1) {
            // Root readiness alone does not imply the outgoing route is gone.
            expect(key('home-people-list'), findsOneWidget);
          }
          await corePeopleJourneyWaitForReturn(tester);
          expect(key('home-people-list'), findsNothing);
          await tester.pump(const Duration(milliseconds: 500));
          expect(h.peopleReads, 2);
          expect(h.haReads, 0);
          expect(h.resourceReads, 0);
          expect(h.writes, isEmpty);
          expect(h.userReads, 0);
          expect(h.grantReads, 0);
          expect(h.personRequests.every((request) => request.method == 'GET'),
              isTrue);
          expect(find.text('Deniz Öztürk'), findsNothing);

          // A fresh explicit opening remains the only next list read.
          timeDilation = originalDilation;
          await press(tester, 'home-people-entry');
          expect(key('home-people-empty'), findsOneWidget);
          expect(h.peopleReads, 3);
          expect(h.haReads, 0);
          expect(h.writes, isEmpty);
        } finally {
          timeDilation = originalDilation;
        }
      },
    );
  }
}
