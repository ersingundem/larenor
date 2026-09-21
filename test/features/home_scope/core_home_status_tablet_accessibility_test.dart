import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/home_scope/presentation/core_home_status_screen.dart';
import 'package:larenor/features/home_scope/presentation/home_source_screen.dart';
import 'package:larenor/features/home_documents/presentation/home_documents_route.dart';
import 'package:larenor/features/camera_search/presentation/camera_search_route.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

import '../../core/home_scope_fixture.dart';

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        'Core home status uses the shared tablet surface $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          final harness = ScopeHarness(HomeSource.verifiedCore);
          try {
            await harness.signIn();
            await harness.mount(
              tester,
              locale: language,
              width: width,
              scale: 2,
            );
            final l10n = AppLocalizations.of(
              tester.element(find.byType(CoreHomeStatusScreen)),
            );
            Future<void> reveal(Finder target) async {
              final scrollable = find.byType(Scrollable).first;
              tester.state<ScrollableState>(scrollable).position.jumpTo(0);
              await tester.pump();
              await tester.scrollUntilVisible(
                target,
                400,
                scrollable: scrollable,
                maxScrolls: 20,
              );
              await tester.pumpAndSettle();
            }

            expect(find.byType(ServiceRootScaffold), findsOneWidget);
            expect(find.byType(SettingsSection), findsAtLeastNWidgets(1));
            expect(find.byType(SettingsActionTile), findsWidgets);
            final inventory = find.byKey(
              const ValueKey('core-home-inventory-action'),
            );
            await reveal(inventory);
            expect(inventory, findsOneWidget);
            expect(tester.getRect(inventory).height, greaterThanOrEqualTo(48));
            final presence = find.byKey(
              const ValueKey('core-home-room-presence-action'),
            );
            await reveal(presence);
            expect(presence, findsOneWidget);
            expect(tester.getRect(presence).height, greaterThanOrEqualTo(48));
            expect(
              tester.getSemantics(presence).flagsCollection.isButton,
              isTrue,
            );
            final documents = find.byKey(
              const ValueKey('core-home-documents-action'),
            );
            await reveal(documents);
            expect(documents, findsOneWidget);
            expect(tester.getRect(documents).height, greaterThanOrEqualTo(48));
            expect(
              tester.getSemantics(documents).label,
              contains(l10n.inventoryDocuments),
            );
            await tester.ensureVisible(documents);
            await tester.pumpAndSettle();
            await tester.tap(documents);
            await tester.pump();
            expect(find.byType(HomeDocumentsRoute), findsOneWidget);
            await tester.pageBack();
            await tester.pumpAndSettle();
            final reservations = find.byKey(
              const ValueKey('core-home-reservations-action'),
            );
            await reveal(reservations);
            expect(reservations, findsOneWidget);
            expect(
              tester.getRect(reservations).height,
              greaterThanOrEqualTo(48),
            );
            expect(
              tester.getSemantics(reservations).label,
              contains(l10n.resourceReservationsTitle),
            );
            final catalog = find.byKey(
              const ValueKey('core-home-resource-catalog-action'),
            );
            await reveal(catalog);
            expect(catalog, findsOneWidget);
            expect(tester.getRect(catalog).height, greaterThanOrEqualTo(48));
            expect(
              tester.getSemantics(catalog).label,
              contains(l10n.resourceCatalogEntry),
            );
            final familyBoard = find.byKey(
              const ValueKey('core-home-family-board-action'),
            );
            await reveal(familyBoard);
            expect(familyBoard, findsOneWidget);
            expect(
              tester.getRect(familyBoard).height,
              greaterThanOrEqualTo(48),
            );
            final cameraSearch = find.byKey(
              const ValueKey('core-home-camera-search-action'),
            );
            await reveal(cameraSearch);
            expect(cameraSearch, findsOneWidget);
            expect(
              tester.getRect(cameraSearch).height,
              greaterThanOrEqualTo(48),
            );
            final headings = find.bySemanticsLabel(l10n.homeSourceCore);
            expect(headings, findsWidgets);
            expect(
              headings.evaluate().any((element) {
                final node = tester.getSemantics(
                  find.byElementPredicate(
                    (candidate) => identical(candidate, element),
                  ),
                );
                return node.flagsCollection.isHeader &&
                    !node.flagsCollection.isButton;
              }),
              isTrue,
            );

            final action = find.byKey(
              const ValueKey('core-home-source-action'),
            );
            await reveal(action);
            final actionNode = tester.getSemantics(action);
            expect(actionNode.label, contains(l10n.homeSourceTitle));
            expect(actionNode.flagsCollection.isButton, isTrue);
            expect(actionNode.rect.width, greaterThanOrEqualTo(48));
            expect(actionNode.rect.height, greaterThanOrEqualTo(48));

            tester.view.physicalSize = Size(width == 600 ? 1200 : 600, 1000);
            await tester.pumpAndSettle();
            for (final target in [
              action,
              inventory,
              presence,
              documents,
              reservations,
              catalog,
              familyBoard,
            ]) {
              await reveal(target);
              expect(target, findsOneWidget);
            }
            await reveal(cameraSearch);
            await tester.tap(cameraSearch);
            await flush(tester);
            expect(find.byType(CameraSearchRoute), findsOneWidget);
            harness.router(tester).pop();
            await flush(tester);
            expect(tester.takeException(), isNull);

            await reveal(action);
            final label = find.descendant(
              of: action,
              matching: find.text(l10n.homeSourceTitle),
            );
            Focus.of(tester.element(label)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await flush(tester);
            expect(find.byType(HomeSourceScreen), findsOneWidget);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
}
