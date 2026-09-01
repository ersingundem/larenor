import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/presentation/entity_picker_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

void main() {
  Widget wrap(Widget child) => CupertinoApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );

  testWidgets('shows the generic empty message when none is given', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const EntityPickerScreen(entities: [])));

    expect(find.text('No entities found'), findsOneWidget);
  });

  testWidgets(
    'shows a custom emptyMessage override instead of the generic one',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          const EntityPickerScreen(
            entities: [],
            emptyMessage: 'Not connected to Home Assistant.',
          ),
        ),
      );

      expect(find.text('Not connected to Home Assistant.'), findsOneWidget);
      expect(find.text('No entities found'), findsNothing);
    },
  );
}
