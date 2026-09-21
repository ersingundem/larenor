import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/room_presence/presentation/room_presence_route.dart';
import 'package:larenor/features/settings/presentation/panes/integrations_pane.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        '$language settings discovers room presence at $width and 2x',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final semantics = tester.ensureSemantics();
          await tester.pumpWidget(
            ProviderScope(
              child: CupertinoApp(
                locale: Locale(language),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
                home: const IntegrationsPane(),
              ),
            ),
          );
          await tester.pump();
          final action = find.byKey(
            const ValueKey('integrations-room-presence-action'),
          );
          expect(action, findsOneWidget);
          expect(tester.getRect(action).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(action).flagsCollection.isButton, isTrue);
          final label = find.descendant(
            of: action,
            matching: find.text(
              language == 'tr' ? 'Oda varlığı' : 'Room presence',
            ),
          );
          Focus.of(tester.element(label)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byType(RoomPresenceRoute), findsOneWidget);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }
}
