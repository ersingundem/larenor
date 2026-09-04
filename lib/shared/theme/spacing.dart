import 'package:flutter/cupertino.dart';

/// The 4pt grid every gap and inset in the app snaps to.
///
/// Spacing was previously ad hoc — `1, 2, 6, 10, 18, 22` all appeared as
/// one-off nudges, and section headers were inset 20pt while the content
/// they labelled was inset 16pt, so every heading sat visibly misaligned
/// with its own first tile.
abstract final class Gap {
  static const xxs = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const xxxl = 32.0;
  static const huge = 48.0;

  // Vertical spacers, so screens don't restate `SizedBox(height: …)`.
  static const vXs = SizedBox(height: xs);
  static const vSm = SizedBox(height: sm);
  static const vMd = SizedBox(height: md);
  static const vLg = SizedBox(height: lg);
  static const vXl = SizedBox(height: xl);
  static const vXxl = SizedBox(height: xxl);
  static const vXxxl = SizedBox(height: xxxl);

  static const hXs = SizedBox(width: xs);
  static const hSm = SizedBox(width: sm);
  static const hMd = SizedBox(width: md);
  static const hLg = SizedBox(width: lg);
}

abstract final class Insets {
  /// The horizontal gutter for page content. Headers and the content they
  /// label both use this, so they line up.
  static const pageGutter = Gap.lg;

  static const page = EdgeInsets.symmetric(horizontal: pageGutter);

  /// Padding inside a dashboard/media tile.
  static const tile = EdgeInsets.all(Gap.md);

  /// Padding for a centred empty or error state.
  static const emptyState = EdgeInsets.symmetric(
    horizontal: Gap.xxxl,
    vertical: Gap.xxl,
  );

  /// A form screen's content padding.
  static const form = EdgeInsets.all(Gap.xxl);

  /// A section heading: gutter-aligned, with air above it and a smaller
  /// gap to the content it introduces.
  static const sectionHeader = EdgeInsets.fromLTRB(
    pageGutter,
    Gap.xl,
    pageGutter,
    Gap.md,
  );
}
