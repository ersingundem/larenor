import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ambient/presentation/ambient_content_settings.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets('${locale.languageCode} $width 2x content actions are accessible', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(CupertinoApp(
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const CupertinoPageScaffold(child: AmbientContentSettings()),
        ));
        await tester.pumpAndSettle();
        for (final key in const ['ambient-add-video', 'ambient-add-pdf', 'ambient-add-web']) {
          final action = find.byKey(ValueKey(key));
          expect(action, findsOneWidget);
          expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(action).getSemanticsData().flagsCollection.isButton, isTrue);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
