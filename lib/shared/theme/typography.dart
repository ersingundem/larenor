import 'package:flutter/cupertino.dart';

/// Apple's iOS type scale, at the default (Large) Dynamic Type setting.
///
/// Every text style in the app comes from here rather than a hand-picked
/// number. Before this existed there were sixteen different font sizes in
/// use — including 12, 12.5 and 13 for the same "tile subtitle" role in
/// tiles sitting side by side in one grid — with no way to change any of
/// it globally.
///
/// The values are Apple's published sizes, not an invented scale. That
/// matters twice over here: it's what makes the app read as genuinely
/// iOS, and the app was previously *undersized* against it (tile titles
/// at 13–14 where iOS says 15), so adopting it also fixes legibility on a
/// wall-mounted panel read from across a room.
abstract final class AppText {
  /// The bundled San Francisco substitute. See `pubspec.yaml` for why a
  /// custom family is necessary rather than the Cupertino default.
  static const fontFamily = 'Inter';

  static const largeTitle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 34,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.37,
  );

  static const title1 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.36,
  );

  static const title2 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.35,
  );

  static const title3 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.38,
  );

  /// Body size at semibold — iOS's style for a row's primary label.
  static const headline = TextStyle(
    fontFamily: fontFamily,
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.41,
  );

  static const body = TextStyle(
    fontFamily: fontFamily,
    fontSize: 17,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.41,
  );

  static const callout = TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.32,
  );

  static const subhead = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.24,
  );

  static const footnote = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.08,
  );

  static const caption1 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w400,
  );

  /// iOS's smallest text style. Nothing should go below this — the app
  /// previously had 10pt labels, under Apple's own floor.
  static const caption2 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 11,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.07,
  );

  // ---------------------------------------------------------------------
  // Semantic roles. Screens should reach for these, so a decision like
  // "how big is a tile title" is made once.
  // ---------------------------------------------------------------------

  /// Heading above a section of content ("Favourites", a room name,
  /// "Continue watching"). Replaces five different treatments.
  static const sectionHeader = title2;

  /// A dashboard or media tile's primary label.
  static final tileTitle = subhead.copyWith(fontWeight: FontWeight.w600);

  /// The state or secondary line under a tile title.
  static const tileSubtitle = footnote;

  /// The caption under a poster.
  static const posterCaption = footnote;

  /// Explanatory text under a form or section.
  static const hint = footnote;

  static final emptyStateTitle = title3;
  static const emptyStateBody = subhead;
}

/// The Cupertino text theme, so widgets that read from the theme (nav bar
/// titles, list tiles, buttons, dialogs) pick up Inter and the scale
/// without every call site restating it.
const appTextTheme = CupertinoTextThemeData(
  primaryColor: CupertinoColors.systemBlue,
  textStyle: AppText.body,
  actionTextStyle: AppText.body,
  tabLabelTextStyle: AppText.caption2,
  navTitleTextStyle: AppText.headline,
  navLargeTitleTextStyle: AppText.largeTitle,
  navActionTextStyle: AppText.body,
  pickerTextStyle: AppText.title3,
  dateTimePickerTextStyle: AppText.title3,
);
