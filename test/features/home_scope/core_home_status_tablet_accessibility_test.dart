import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/home_scope/presentation/core_home_status_screen.dart';
import 'package:larenor/features/home_scope/presentation/home_source_screen.dart';
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
