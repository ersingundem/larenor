import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/home_scope/presentation/core_home_status_screen.dart';
import 'package:larenor/features/home_scope/presentation/home_source_screen.dart';
import 'package:larenor/features/home_documents/presentation/home_documents_route.dart';
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

            expect(find.byType(ServiceRootScaffold), findsOneWidget);
            expect(find.byType(SettingsSection), findsAtLeastNWidgets(1));
            expect(find.byType(SettingsActionTile), findsAtLeastNWidgets(2));
            final inventory = find.byKey(
              const ValueKey('core-home-inventory-action'),
            );
            expect(inventory, findsOneWidget);
            expect(tester.getRect(inventory).height, greaterThanOrEqualTo(48));
            final documents = find.byKey(
              const ValueKey('core-home-documents-action'),
            );
            expect(documents, findsOneWidget);
            expect(tester.getRect(documents).height, greaterThanOrEqualTo(48));
            expect(
              tester.getSemantics(documents).label,
              contains(l10n.inventoryDocuments),
            );
            await tester.ensureVisible(documents);
            await tester.tap(documents);
            await tester.pump();
            expect(find.byType(HomeDocumentsRoute), findsOneWidget);
            await tester.pageBack();
            await tester.pumpAndSettle();
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
            await tester.ensureVisible(action);
            await tester.pump();
            final actionNode = tester.getSemantics(action);
            expect(actionNode.label, contains(l10n.homeSourceTitle));
            expect(actionNode.flagsCollection.isButton, isTrue);
            expect(actionNode.rect.width, greaterThanOrEqualTo(48));
            expect(actionNode.rect.height, greaterThanOrEqualTo(48));

            tester.view.physicalSize = Size(width == 600 ? 1200 : 600, 1000);
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('core-home-source-action')),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('core-home-inventory-action')),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('core-home-documents-action')),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);

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
