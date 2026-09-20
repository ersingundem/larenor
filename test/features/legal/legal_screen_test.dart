import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/legal/presentation/legal_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';

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
      await tester.scrollUntilVisible(row, 250, maxScrolls: 20);
      await tester.ensureVisible(row);
      await tester.pump();
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

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets(
        '${locale.languageCode} legal hierarchy fits ${width.toInt()}px tablets',
        (tester) async {
          final semantics = tester.ensureSemantics();
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            CupertinoApp(
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const LegalScreen(),
            ),
          );
          await tester.pumpAndSettle();
          final l10n = await AppLocalizations.delegate.load(locale);
          final source = find.text(l10n.legalSource);
          expect(source, findsOneWidget);
          expect(tester.getSemantics(source).flagsCollection.isHeader, isTrue);
          expect(find.byType(SettingsActionTile), findsAtLeastNWidgets(9));
          expect(
            tester.getSize(find.byType(ListView)).width,
            width > 780 ? 780 : width,
          );
          expect(
            tester
                .getSize(find.byKey(const ValueKey('legal-copy-source')))
                .height,
            greaterThanOrEqualTo(48),
          );
          final copy = tester.getSemantics(
            find.byKey(const ValueKey('legal-copy-source')),
          );
          expect(copy.flagsCollection.isButton, isTrue);
          expect(copy.flagsCollection.isHeader, isFalse);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }

  testWidgets('document rows keep independent tap and keyboard activation', (
    tester,
  ) async {
    await tester.runAsync(() => rootBundle.loadString('LICENSE'));
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LegalScreen(),
      ),
    );
    await tester.pump();
    final row = find.byKey(const ValueKey('legal-document-LICENSE'));
    await tester.ensureVisible(row);
    await tester.pump();
    final navigator = Navigator.of(tester.element(row));
    await tester.tap(row);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(navigator.canPop(), isTrue);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(navigator.canPop(), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('document callback rendered before background is expired', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LegalScreen(),
      ),
    );
    await tester.pump();
    final row = find.byKey(const ValueKey('legal-document-LICENSE'));
    final old = tester.widget<CupertinoButton>(row).onPressed!;
    final navigator = Navigator.of(tester.element(row));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    old();
    await tester.pump();

    expect(navigator.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });
}
