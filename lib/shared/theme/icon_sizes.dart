/// Icon sizes, down from the fourteen distinct values previously inline —
/// including a lone odd-numbered 19, and empty-state glyphs at 40, 44 and
/// 48 across four screens doing the identical thing.
abstract final class IconSizes {
  /// Inline with caption text — badges, status glyphs.
  static const caption = 16.0;

  /// Inline with body text, and the default for list-row glyphs.
  static const body = 20.0;

  /// A tile's leading glyph. Flutter's own default is also 24, so
  /// un-sized `Icon`s already agree with this.
  static const tile = 24.0;

  /// Media transport controls.
  static const control = 28.0;

  /// The glyph in a centred empty or error state.
  static const hero = 48.0;

  /// The minimum tappable edge Apple's guidelines require. Wrapping a
  /// small icon in a box this size is what fixes a 16pt glyph that was
  /// also the only way to dismiss something.
  static const minTapTarget = 44.0;
}
