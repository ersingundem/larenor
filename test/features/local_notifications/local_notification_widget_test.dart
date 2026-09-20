import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/local_notifications/domain/local_notification_models.dart';
import 'package:larenor/features/local_notifications/presentation/local_notification_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

LocalNotificationEvent privateEvent([int sequence = 1]) =>
    LocalNotificationEvent.fromJson({
      'schemaVersion': 1,
      'id': (sequence == 1 ? 'a' : 'b') * 32,
      'sequence': sequence,
      'category': 'security',
      'sensitivity': 'private',
      'title': 'Secret title',
      'body': 'Secret body',
      'target': '/today',
      'createdAt': 1788609600.0,
      'deliveryState': 'delivered',
      'readState': 'unread',
      'acknowledged': false,
      'publicProjection': {
        'title': 'Larenor',
        'body': '',
        'target': null,
        'redacted': true,
      },
    });

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets(
        'private card is redacted keyboard accessible at ${locale.languageCode} $width 2x',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 700);
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          var opens = 0;
          await tester.pumpWidget(
            CupertinoApp(
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: CupertinoPageScaffold(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: LocalNotificationPreviewGrid(
                    events: [privateEvent(), privateEvent(2)],
                    enabled: true,
                    onOpen: (_) => opens++,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Secret title'), findsNothing);
          expect(find.text('Secret body'), findsNothing);
          expect(find.text('Larenor'), findsNWidgets(2));
          expect(tester.takeException(), isNull);
          final button = find.byKey(const ValueKey('notification-1'));
          expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
          final first = tester.getTopLeft(button);
          final second = tester.getTopLeft(
            find.byKey(const ValueKey('notification-2')),
          );
          if (width >= 1200) {
            expect(second.dx, greaterThan(first.dx));
            expect(second.dy, first.dy);
          } else {
            expect(second.dx, first.dx);
            expect(second.dy, greaterThan(first.dy));
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          expect(opens, 1);
          final semantics = tester.getSemantics(button);
          expect(semantics.label, contains('Larenor'));
        },
      );
    }
  }
}
