import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/shared/theme/typography.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

/// Flutter's `CupertinoListSection.insetGrouped` hardcodes a 20pt bold
/// header and leaves footers at the theme's body size, which is what made
/// the settings screens look top-heavy. These lock in iOS's real values.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    CupertinoApp(
      theme: larenorTheme(brightness: Brightness.light),
      home: CupertinoPageScaffold(child: child),
    ),
  );

  TextStyle styleOf(WidgetTester tester, String text) {
    final element = tester.element(find.text(text));
    return DefaultTextStyle.of(element).style;
  }

  testWidgets('header renders at footnote size, not 20pt bold', (tester) async {
    await pump(
      tester,
      const SettingsSection(
        header: Text('DISPLAY'),
        children: [CupertinoListTile(title: Text('Keep screen on'))],
      ),
    );

    final style = styleOf(tester, 'DISPLAY');
    expect(style.fontSize, AppText.footnote.fontSize);
    expect(style.fontWeight, isNot(FontWeight.bold));
  });

  testWidgets('footer renders at footnote size, not body size', (tester) async {
    await pump(
      tester,
      const SettingsSection(
        footer: Text('A shared overnight window.'),
        children: [CupertinoListTile(title: Text('Row'))],
      ),
    );

    final style = styleOf(tester, 'A shared overnight window.');
    expect(style.fontSize, AppText.footnote.fontSize);
    expect(style.fontSize, lessThan(AppText.body.fontSize!));
  });

  testWidgets('header and footer are secondary, rows stay primary', (
    tester,
  ) async {
    await pump(
      tester,
      const SettingsSection(
        header: Text('SECURITY'),
        footer: Text('No PIN set.'),
        children: [CupertinoListTile(title: Text('Set PIN'))],
      ),
    );

    final headerColor = styleOf(tester, 'SECURITY').color;
    final rowColor = styleOf(tester, 'Set PIN').color;

    expect(headerColor, isNotNull);
    expect(rowColor, isNotNull);
    expect(headerColor, isNot(rowColor));
  });

  testWidgets('uses the bundled family so it matches the rest of the app', (
    tester,
  ) async {
    await pump(
      tester,
      const SettingsSection(
        header: Text('CONNECTION'),
        children: [CupertinoListTile(title: Text('Server'))],
      ),
    );

    expect(styleOf(tester, 'CONNECTION').fontFamily, AppText.fontFamily);
  });

  testWidgets('renders without a header or footer', (tester) async {
    await pump(
      tester,
      const SettingsSection(
        children: [CupertinoListTile(title: Text('Sign out'))],
      ),
    );

    expect(find.text('Sign out'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
