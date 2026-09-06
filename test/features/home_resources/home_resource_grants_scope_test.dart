import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/home_resources/data/home_resources_api.dart';
import 'package:larenor/features/home_resources/presentation/home_resource_grants_screen.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'home_resource_admin_fixture.dart';
import 'home_resource_grants_ui_test.dart';

void main() {
  for (final source in [HomeSource.verifiedCore, HomeSource.directLocal]) {
    testWidgets(
      'grants retained state fails closed when reparented to $source',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(700, 1200);
        addTearDown(tester.view.reset);
        final a = GrantsHarness(), b = GrantsHarness();
        b.source.value = source;
        final homeA = HomeSessionController(
              store: a.source,
              account: a.account,
            ),
            homeB = HomeSessionController(store: b.source, account: b.account);
        await a.account.initialize();
        await b.account.initialize();
        await a.signIn();
        await b.signIn();
        await homeA.initialize();
        await homeB.initialize();
        homeA.runtimeMounted(homeA.runtimeIdentity);
        homeB.runtimeMounted(homeB.runtimeIdentity);
        ProviderContainer container(
          GrantsHarness h,
          HomeSessionController home,
        ) => ProviderContainer(
          overrides: [
            homeSessionControllerProvider.overrideWithValue(home),
            homeResourcesApiFactoryProvider.overrideWithValue(
              (endpoint) => LarenorServerApi(
                endpoint: endpoint,
                client: MockClient(h.handle),
                clock: () => h.now,
              ),
            ),
            homeResourcesClockProvider.overrideWithValue(() => h.now),
            windowPolicySnapshotProvider.overrideWith((_) async* {
              yield h.currentWindow;
            }),
          ],
        );
        final containerA = container(a, homeA),
            containerB = container(b, homeB);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          containerA.dispose();
          containerB.dispose();
          homeA.dispose();
          homeB.dispose();
          a.account.dispose();
          b.account.dispose();
        });
        var current = containerA;
        late StateSetter rebuild;
        final stateKey = GlobalKey();
        // Both old source/account/container remain alive; only the visible binding changes.
        await tester.pumpWidget(
          CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return UncontrolledProviderScope(
                  container: current,
                  child: AppInteractionScope(
                    controller: homeA.interaction,
                    child: HomeResourceGrantsScreen(
                      key: stateKey,
                      target: HomeResourceRecord.fromJson(
                        a.records.first,
                        expectedContext: a.account.session!.context!,
                      ),
                      gateCurrent: () => true,
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await flush(tester);
        await adminPress(tester, 'resource-grants-user-${'3' * 32}');
        const action = 'resource-grants-save';
        final held = tester
            .widget<CupertinoButton>(adminKey(action))
            .onPressed!;
        final original = stateKey.currentState, reads = a.grantReads;
        rebuild(() => current = containerB);
        await flush(tester);
        expect(stateKey.currentState, same(original));
        held();
        await flush(tester);
        expect(a.puts, isEmpty);
        expect(a.grantReads, reads);
        expect(b.grantReads, 0);
        expect(b.puts, isEmpty);
        expect(find.text('person_3'), findsNothing);
        expect(adminKey('resource-grants-save'), findsNothing);
        expect(homeA.interaction.active, isTrue);
        expect(a.account.session, isNotNull);
      },
    );
  }
}
