import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/shared/theme/icon_sizes.dart';
import 'package:larenor/shared/theme/spacing.dart';
import 'package:larenor/shared/theme/typography.dart';
import 'package:larenor/shared/widgets/poster_card.dart';

void main() {
  group('type scale', () {
    test('matches Apple\'s published iOS sizes', () {
      expect(AppText.largeTitle.fontSize, 34);
      expect(AppText.title1.fontSize, 28);
      expect(AppText.title2.fontSize, 22);
      expect(AppText.title3.fontSize, 20);
      expect(AppText.headline.fontSize, 17);
      expect(AppText.body.fontSize, 17);
      expect(AppText.callout.fontSize, 16);
      expect(AppText.subhead.fontSize, 15);
      expect(AppText.footnote.fontSize, 13);
      expect(AppText.caption1.fontSize, 12);
      expect(AppText.caption2.fontSize, 11);
    });

    test('nothing drops below caption2, iOS\'s smallest style', () {
      final sizes = [
        AppText.largeTitle,
        AppText.title1,
        AppText.title2,
        AppText.title3,
        AppText.headline,
        AppText.body,
        AppText.callout,
        AppText.subhead,
        AppText.footnote,
        AppText.caption1,
        AppText.caption2,
        AppText.tileTitle,
        AppText.tileSubtitle,
        AppText.posterCaption,
        AppText.sectionHeader,
      ].map((s) => s.fontSize!);

      expect(sizes.reduce((a, b) => a < b ? a : b), greaterThanOrEqualTo(11));
    });

    test('every style uses the bundled family, not the platform default', () {
      // On Android the Cupertino default silently falls back to Roboto, so
      // an unset family here would quietly un-do the whole typeface fix.
      for (final style in [
        AppText.largeTitle,
        AppText.body,
        AppText.footnote,
        AppText.tileTitle,
        AppText.posterCaption,
      ]) {
        expect(style.fontFamily, AppText.fontFamily);
      }
    });

    test('semantic roles resolve to a single size each', () {
      // The defect this guards: tile titles were 12, 13 and 14pt across
      // eight tile types sitting side by side in the same grid.
      expect(AppText.tileTitle.fontSize, AppText.subhead.fontSize);
      expect(AppText.tileTitle.fontWeight, FontWeight.w600);
      expect(AppText.tileSubtitle.fontSize, AppText.footnote.fontSize);
      expect(AppText.posterCaption.fontSize, AppText.footnote.fontSize);
      expect(AppText.sectionHeader.fontSize, AppText.title2.fontSize);
    });
  });

  group('spacing', () {
    test('every step sits on the 4pt grid', () {
      for (final value in [
        Gap.xs,
        Gap.sm,
        Gap.md,
        Gap.lg,
        Gap.xl,
        Gap.xxl,
        Gap.xxxl,
        Gap.huge,
      ]) {
        expect(value % 4, 0, reason: '$value is off the 4pt grid');
      }
    });

    test('headers and the content they label share a gutter', () {
      // These were 20 and 16, so every section title sat visibly
      // misaligned with its own first tile.
      expect(Insets.sectionHeader.left, Insets.page.left);
      expect(Insets.sectionHeader.right, Insets.page.right);
    });
  });

  group('icon sizes', () {
    test('the minimum tap target is Apple\'s 44pt', () {
      expect(IconSizes.minTapTarget, 44);
    });

    test('sizes ascend without duplicates', () {
      final sizes = [
        IconSizes.caption,
        IconSizes.body,
        IconSizes.tile,
        IconSizes.control,
        IconSizes.hero,
      ];
      expect(sizes, orderedEquals(([...sizes]..sort())));
      expect(sizes.toSet(), hasLength(sizes.length));
    });
  });

  group('theme', () {
    test('carries the text theme so widgets inherit the scale', () {
      expect(larenorTheme().textTheme.textStyle.fontFamily, AppText.fontFamily);
    });

    test('every text theme style carries a colour', () {
      // Regression guard. Cupertino's own text theme derives a colour;
      // overriding these styles without one left the text colourless,
      // which rendered white and made list-tile and nav bar titles
      // invisible on a light background.
      final styles = {
        'textStyle': appTextTheme.textStyle,
        'actionTextStyle': appTextTheme.actionTextStyle,
        'tabLabelTextStyle': appTextTheme.tabLabelTextStyle,
        'navTitleTextStyle': appTextTheme.navTitleTextStyle,
        'navLargeTitleTextStyle': appTextTheme.navLargeTitleTextStyle,
        'navActionTextStyle': appTextTheme.navActionTextStyle,
        'pickerTextStyle': appTextTheme.pickerTextStyle,
        'dateTimePickerTextStyle': appTextTheme.dateTimePickerTextStyle,
      };
      for (final entry in styles.entries) {
        expect(
          entry.value.color,
          isNotNull,
          reason: '${entry.key} has no colour and will render white',
        );
      }
    });

    testWidgets('a list tile title renders in the label colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        CupertinoApp(
          theme: larenorTheme(brightness: Brightness.light),
          home: CupertinoPageScaffold(
            child: CupertinoListSection.insetGrouped(
              children: const [CupertinoListTile(title: Text('Connection'))],
            ),
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('Connection'));
      final resolved =
          text.style?.color ??
          DefaultTextStyle.of(tester.element(find.text('Connection')))
              .style
              .color;
      expect(resolved, isNotNull);
      expect(resolved, isNot(const Color(0xFFFFFFFF)));
    });

    test('appearance maps onto a brightness, with system meaning null', () {
      expect(AppAppearance.system.brightness, isNull);
      expect(AppAppearance.light.brightness, Brightness.light);
      expect(AppAppearance.dark.brightness, Brightness.dark);
    });
  });

  group('PosterCard.heightFor', () {
    testWidgets('leaves room for the caption at the default text size', (
      tester,
    ) async {
      late double height;
      late BuildContext ctx;
      await tester.pumpWidget(
        CupertinoApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      height = PosterCard.heightFor(120, ctx);

      // Artwork alone is 180pt at this width; the row that hardcoded 190
      // clipped its own captions.
      expect(height, greaterThan(180 + 13));
    });

    testWidgets('grows with the system text scale', (tester) async {
      late BuildContext ctx;
      Widget app(double scale) => CupertinoApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      await tester.pumpWidget(app(1));
      final normal = PosterCard.heightFor(120, ctx);
      await tester.pumpWidget(app(2));
      final large = PosterCard.heightFor(120, ctx);

      expect(large, greaterThan(normal));
    });
  });
}
