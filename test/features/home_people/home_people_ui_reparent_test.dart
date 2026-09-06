import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/home_people/data/home_people_providers.dart';
import 'package:larenor/features/home_people/presentation/home_people_route.dart';
import 'package:larenor/features/home_people/presentation/home_people_screen.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'home_people_ui_boundary_test.dart' show held, draft;
import 'home_people_ui_fixture.dart';
import 'home_people_ui_test.dart' show key, press;

void main() {
  for (final pending in [false, true]) {
    testWidgets(
      'same mounted actual screen reparent retires ${pending ? 'late401' : 'held save'} with old container and identical account/home alive',
      (tester) async {
        final h = PeopleUiHarness();
        await h.account.initialize();
        await h.signIn();
        final home = HomeSessionController(store: h.source, account: h.account);
        await home.initialize();
        home.runtimeMounted(home.runtimeIdentity);
        final interaction = AppInteractionController(), screenKey = GlobalKey();
        var requestsB = 0;
        ProviderContainer container(bool b) => ProviderContainer(
          overrides: [
            homeSessionControllerProvider.overrideWithValue(home),
            homePeopleClockProvider.overrideWithValue(() => h.now),
            windowPolicySnapshotProvider.overrideWith((_) async* {
              yield const WindowPolicySnapshot(
                supported: false,
                isResumed: true,
                hasWindowFocus: true,
                reason: WindowRestrictionReason.unsupported,
              );
            }),
            homePeopleApiFactoryProvider.overrideWithValue(
              (endpoint) => LarenorServerApi(
                endpoint: endpoint,
                client: MockClient((request) {
                  if (b) requestsB++;
                  return h.handle(request);
                }),
                clock: () => h.now,
              ),
            ),
          ],
        );
        final a = container(false), b = container(true);
        Widget app(ProviderContainer c) => UncontrolledProviderScope(
          container: c,
          child: AppInteractionScope(
            controller: interaction,
            child: CupertinoApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: HomePeopleScreen(
                key: screenKey,
                adminManagement: true,
                gateCurrent: () => true,
              ),
            ),
          ),
        );
        await tester.pumpWidget(app(a));
        await flush(tester);
        await draft(tester);
        final old = held(tester, 'home-people-save'),
            element = screenKey.currentContext,
            state = tester.state(find.byType(HomePeopleRoute));
        final late = Completer<http.Response>();
        if (pending) {
          h.pendingWrite = late;
          await press(tester, 'home-people-save');
        }
        await tester.pumpWidget(app(b));
        await flush(tester);
        expect(screenKey.currentContext, same(element));
        expect(tester.state(find.byType(HomePeopleRoute)), same(state));
        expect(
          a.read(homeSessionControllerProvider),
          same(b.read(homeSessionControllerProvider)),
        );
        old();
        if (pending) {
          late.complete(
            h.json({
              'error': {'code': 'unauthorized'},
            }, 401),
          );
          h.pendingWrite = null;
        }
        await flush(tester);
        expect(h.writes.length, pending ? 1 : 0);
        expect(requestsB, 0);
        expect(find.text('Private draft'), findsNothing);
        expect(find.text('Deniz Öztürk'), findsNothing);
        expect(h.account.session, isNotNull);
        expect(h.store.value, isNotNull);
        await tester.pumpWidget(app(a));
        await flush(tester);
        old();
        expect(requestsB, 0);
        expect(h.peopleReads, 1);
        expect(h.writes.length, pending ? 1 : 0);
        expect(key('home-people-save'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await flush(tester);
        a.dispose();
        b.dispose();
        interaction.dispose();
        home.dispose();
        h.account.dispose();
        await h.window.close();
      },
    );
  }
}
