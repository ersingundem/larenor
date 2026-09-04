import 'package:flutter/cupertino.dart';

import '../shared/theme/typography.dart';
import '../shared/theme/app_colors.dart';

/// How the app picks between light and dark.
enum AppAppearance {
  /// Follow the tablet's own light/dark setting.
  system,
  light,
  dark;

  Brightness? get brightness => switch (this) {
    AppAppearance.system => null,
    AppAppearance.light => Brightness.light,
    AppAppearance.dark => Brightness.dark,
  };
}

/// The app's single Cupertino theme.
///
/// Cupertino's dynamic colours (`CupertinoColors.systemBackground` and
/// friends) resolve light/dark from the ambient brightness, so one theme
/// covers both — but only for colours that actually get resolved. A
/// dynamic colour handed straight to `TextStyle.color`, `Icon.color` or
/// `ColoredBox.color` is *not* resolved automatically and will render its
/// light variant forever, which is why those call sites have to use
/// `.resolveFrom(context)` explicitly.
///
/// [brightness] is null when following the system.
CupertinoThemeData larenorTheme({Brightness? brightness}) => CupertinoThemeData(
  brightness: brightness,
  primaryColor: CupertinoColors.systemBlue,
  textTheme: appTextTheme,
  scaffoldBackgroundColor: AppColors.canvas,
  barBackgroundColor: AppColors.navigation,
);

/// Convenience for tests and previews that don't need an appearance
/// override.
final larenorCupertinoTheme = larenorTheme();
