import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/presentation/entity_multi_picker_screen.dart';
import 'package:larenor/features/dashboard/presentation/entity_picker_screen.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _entity = HaEntity(
  entityId: 'light.lamp',
  state: 'off',
  attributes: {'friendly_name': 'Living room lamp'},
);

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

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets('${locale.languageCode} selection workflows fit '
          '${width.toInt()}px at 2x text', (tester) async {
        final semantics = tester.ensureSemantics();
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        try {
          Widget app(Widget home) => CupertinoApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: home,
          );

          await tester.pumpWidget(
            app(const EntityPickerScreen(entities: [_entity])),
          );
          await tester.pumpAndSettle();
          expect(find.byType(AppSurface), findsOneWidget);
          expect(
            find.byKey(const ValueKey('entity-picker-search')),
            findsOneWidget,
          );
          final single = find.byKey(const ValueKey('entity-picker-light.lamp'));
          expect(tester.getRect(single).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(single).flagsCollection.isButton, isTrue);

          await tester.pumpWidget(
            app(
              const EntityMultiPickerScreen(entities: [_entity], title: 'Room'),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsOneWidget);
          expect(
            find.byKey(const ValueKey('entity-multi-picker-search')),
            findsOneWidget,
          );
          final row = find.byKey(
            const ValueKey('entity-multi-picker-light.lamp'),
          );
          expect(tester.getRect(row).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(row).flagsCollection.isButton, isTrue);
          await tester.tap(row);
          await tester.pump();
          expect(
            tester.getSemantics(row).flagsCollection.isSelected,
            ui.Tristate.isTrue,
          );
          final add = find.byKey(const ValueKey('entity-multi-picker-add'));
          expect(tester.getRect(add).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(add).flagsCollection.isButton, isTrue);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
