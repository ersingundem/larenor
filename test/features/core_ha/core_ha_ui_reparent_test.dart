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
import 'package:larenor/features/core_ha/data/core_ha_providers.dart';
import 'package:larenor/features/core_ha/presentation/core_ha_route.dart';
import 'package:larenor/features/core_ha/presentation/core_ha_screen.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'core_ha_ui_boundary_test.dart' show held, preview;
import 'core_ha_ui_fixture.dart';

import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'core_ha_ui_test.dart' show key, press;

void main() {
  for (final pending in [false, true]) {
    testWidgets(
      'same mounted actual screen reparent retires ${pending ? 'late401' : 'held confirm'} with old container and identical account/home alive',
      (tester) async {
        final h = HaUiHarness();
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
            coreHaClockProvider.overrideWithValue(() => h.now),
            windowPolicySnapshotProvider.overrideWith((_) async* {
              yield const WindowPolicySnapshot(
                supported: false,
                isResumed: true,
                hasWindowFocus: true,
                reason: WindowRestrictionReason.unsupported,
              );
            }),
            coreHaApiFactoryProvider.overrideWithValue(
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
              home: CoreHaBindingScreen(
                key: screenKey,
                target: HomeResourceRecord.fromJson(
                  h.f['resource'],
                  expectedContext: ServerContext.fromJson(h.f['context']),
                ),
                gateCurrent: () => true,
              ),
            ),
          ),
        );
        await tester.pumpWidget(app(a));
        await flush(tester);
        await preview(tester, h);
        final old = held(tester, 'core-ha-confirm'),
            element = screenKey.currentContext,
            state = tester.state(find.byType(CoreHaRoute));
        final late = Completer<http.Response>();
        if (pending) {
          h.pendingConfirm = late;
          await press(tester, 'core-ha-confirm');
        }
        await tester.pumpWidget(app(b));
        await flush(tester);
        expect(screenKey.currentContext, same(element));
        expect(tester.state(find.byType(CoreHaRoute)), same(state));
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
          h.pendingConfirm = null;
        }
        await flush(tester);
        expect(
          h.adapterRequests
              .where((r) => r.url.path.endsWith('/binding-confirm'))
              .length,
          pending ? 1 : 0,
        );
        expect(requestsB, 0);
        expect(find.text('switch.synthetic'), findsNothing);
        expect(find.text('Salon anahtarı'), findsNothing);
        expect(h.account.session, isNotNull);
        expect(h.store.value, isNotNull);
        await tester.pumpWidget(app(a));
        await flush(tester);
        old();
        expect(requestsB, 0);
        expect(
          h.adapterRequests
              .where((r) => r.url.path.endsWith('/binding-preview'))
              .length,
          1,
        );
        expect(
          h.adapterRequests
              .where((r) => r.url.path.endsWith('/binding-confirm'))
              .length,
          pending ? 1 : 0,
        );
        expect(key('core-ha-confirm'), findsNothing);
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
