import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/breakpoints.dart';
import 'package:larenor/features/settings/presentation/settings_split_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget wrap(Widget child) => ProviderScope(
  child: CupertinoApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  ),
);

Future<void> pumpAt(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(wrap(const SettingsSplitScreen()));
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('wide layout shows the master list beside a detail pane', (
    tester,
  ) async {
    await pumpAt(tester, const Size(kSplitViewMinWidth + 200, 800));

    // The master list's own title plus the selected pane's title are both
    // on screen at once — that's the split view working.
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Connection'), findsWidgets);
    expect(find.byType(Navigator), findsWidgets);
  });

  testWidgets('narrow layout shows only the master list', (tester) async {
    await pumpAt(tester, const Size(kSplitViewMinWidth - 200, 800));

    expect(find.text('Settings'), findsWidgets);
    // Every category is listed, but no pane is rendered alongside it, so
    // the Display pane's own section header isn't present yet.
    expect(find.text('Display & Brightness'), findsWidgets);
    expect(find.text('Keep screen on'), findsNothing);
  });

  testWidgets('tapping a category in the narrow layout pushes its pane', (
    tester,
  ) async {
    await pumpAt(tester, const Size(kSplitViewMinWidth - 200, 800));

    await tester.tap(find.text('Display & Brightness').first);
    await tester.pumpAndSettle();

    expect(find.text('Keep screen on'), findsOneWidget);
  });

  testWidgets('selecting a category in the wide layout swaps the detail pane', (
    tester,
  ) async {
    await pumpAt(tester, const Size(kSplitViewMinWidth + 200, 800));

    expect(find.text('Keep screen on'), findsNothing);

    await tester.tap(find.text('Display & Brightness').first);
    await tester.pumpAndSettle();

    expect(find.text('Keep screen on'), findsOneWidget);
    // The master list is still there beside it.
    expect(find.text('Security'), findsWidgets);
  });
}
