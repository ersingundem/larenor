import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/shared/theme/typography.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

/// Flutter's `CupertinoListSection.insetGrouped` hardcodes a 20pt bold
/// header and leaves footers at the theme's body size, which is what made
/// the settings screens look top-heavy. These lock in iOS's real values.
void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    double width = 800,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      CupertinoApp(
        theme: larenorTheme(brightness: Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: CupertinoPageScaffold(child: child),
      ),
    );
  }

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

  for (final width in [600.0, 1200.0]) {
    testWidgets('exposes a section heading at $width width and 2x text', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await pump(
          tester,
          const SettingsSection(
            header: Text('STATUS'),
            footer: Text('Connection evidence is read only.'),
            children: [CupertinoListTile(title: Text('Core'))],
          ),
          width: width,
          scale: 2,
        );

        expect(
          tester.getSemantics(find.text('STATUS')).flagsCollection.isHeader,
          isTrue,
        );
        expect(
          tester
              .getSemantics(find.text('Connection evidence is read only.'))
              .flagsCollection
              .isHeader,
          isFalse,
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets('preserves an explicit heading as one semantic container', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pump(
        tester,
        SettingsSection(
          header: Semantics(
            key: const ValueKey('explicit-section-heading'),
            container: true,
            header: true,
            child: const Text('HISTORY'),
          ),
          children: const [CupertinoListTile(title: Text('Receipt'))],
        ),
      );

      final node = tester.getSemantics(
        find.byKey(const ValueKey('explicit-section-heading')),
      );
      expect(node.flagsCollection.isHeader, isTrue);
      expect(node.label, 'HISTORY');
    } finally {
      semantics.dispose();
    }
  });
}
