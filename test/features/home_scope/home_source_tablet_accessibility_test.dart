import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/home_scope/presentation/home_source_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

import '../../core/home_scope_fixture.dart';

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        'home source uses the shared tablet surface $language $width 2x',
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
            harness.router(tester).push('/settings/home-source');
            await flush(tester);
            final l10n = AppLocalizations.of(
              tester.element(find.byType(HomeSourceScreen)),
            );

            expect(find.byType(SettingsSection), findsAtLeastNWidgets(1));
            expect(find.byType(SettingsActionTile), findsAtLeastNWidgets(2));
            final headings = find.bySemanticsLabel(l10n.homeSourceTitle);
            expect(headings, findsWidgets);
            final headingNodes = headings.evaluate().map(
              (element) => tester.getSemantics(
                find.byElementPredicate(
                  (candidate) => identical(candidate, element),
                ),
              ),
            );
            expect(
              headingNodes.any(
                (node) =>
                    node.flagsCollection.isHeader &&
                    !node.flagsCollection.isButton,
              ),
              isTrue,
            );

            final direct = find.byKey(
              const ValueKey('home-source-action-directLocal'),
            );
            final directNode = tester.getSemantics(direct);
            expect(directNode.label, contains(l10n.homeSourceDirect));
            expect(directNode.flagsCollection.isButton, isTrue);
            expect(directNode.rect.width, greaterThanOrEqualTo(48));
            expect(directNode.rect.height, greaterThanOrEqualTo(48));

            final label = find.descendant(
              of: direct,
              matching: find.text(l10n.homeSourceDirect),
            );
            Focus.of(tester.element(label)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await flush(tester);
            expect(harness.source.value, HomeSource.directLocal);
            expect(harness.source.writes, 1);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets('selected source cannot issue a duplicate configuration write', (
    tester,
  ) async {
    final harness = ScopeHarness(HomeSource.directLocal);
    await harness.mount(tester);
    harness.router(tester).push('/settings/home-source');
    await flush(tester);

    final selected = find.byKey(
      const ValueKey('home-source-action-directLocal'),
    );
    expect(tester.widget<CupertinoButton>(selected).onPressed, isNull);
    await tester.tap(selected);
    await flush(tester);
    expect(harness.source.writes, 0);
    expect(harness.source.value, HomeSource.directLocal);
  });

  testWidgets('source read failure is a safe TalkBack live state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final harness = ScopeHarness(HomeSource.verifiedCore);
    harness.source.readFails = true;
    try {
      await harness.mount(tester);
      harness.router(tester).push('/settings/home-source');
      await flush(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(HomeSourceScreen)),
      );
      final status = find.byKey(const ValueKey('home-source-status'));
      expect(tester.getSemantics(status).label, l10n.homeSourceStorageError);
      expect(tester.getSemantics(status).flagsCollection.isLiveRegion, isTrue);
      expect(find.textContaining('source_read_failed'), findsNothing);
      expect(harness.source.value, HomeSource.verifiedCore);
    } finally {
      semantics.dispose();
    }
  });
}
