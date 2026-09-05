import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/legal/presentation/legal_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'all legal notices are available in the actual Flutter asset bundle',
    () async {
      for (final asset in [
        'LICENSE',
        'NOTICE',
        'THIRD_PARTY_NOTICES.md',
        'assets/fonts/OFL.txt',
        'assets/console/novnc/docs/LICENSE.MPL-2.0',
        'assets/console/novnc/LICENSE.txt',
        'assets/console/novnc/vendor/pako/LICENSE',
        'assets/console/xterm/LICENSE',
        'assets/licenses/apksig-APACHE-2.0.txt',
      ]) {
        expect(await rootBundle.loadString(asset), isNotEmpty, reason: asset);
      }
    },
  );

  testWidgets(
    'local source and license remain readable at 320px with large text',
    (tester) async {
      await tester.runAsync(() => rootBundle.loadString('LICENSE'));
      tester.view.physicalSize = const Size(320, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        CupertinoApp(
          locale: const Locale('tr'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const LegalScreen(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(larenorSourceUrl), findsOneWidget);
      expect(tester.takeException(), isNull);
      final row = find.text('Larenor — GNU AGPL v3');
      await tester.scrollUntilVisible(row, 250);
      await tester.runAsync(() async {
        await tester.tap(row);
        await tester.pumpAndSettle();
      });
      expect(
        find.textContaining('GNU AFFERO GENERAL PUBLIC LICENSE'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
