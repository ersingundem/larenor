import 'package:flutter/cupertino.dart';

/// Corner radii, down from the eight distinct values that were previously
/// inline across the app for what are really three roles.
abstract final class Radii {
  /// Small chrome — badges, inline code blocks, thumbnails.
  static const small = 8.0;

  /// Poster and image artwork.
  static const artwork = 10.0;

  /// Cards, grid tiles, modal sheet tops.
  static const card = 14.0;

  /// Large surfaces — the accessory tiles that dominate the dashboard.
  static const large = 18.0;

  static const brSmall = BorderRadius.all(Radius.circular(small));
  static const brArtwork = BorderRadius.all(Radius.circular(artwork));
  static const brCard = BorderRadius.all(Radius.circular(card));
  static const brLarge = BorderRadius.all(Radius.circular(large));

  /// A true capsule. Using a fixed radius for pills was a latent bug: the
  /// category chip's 18pt radius only looked like a capsule while the chip
  /// happened to be ~33pt tall, and stopped being one as soon as the text
  /// scaled up.
  static const brPill = BorderRadius.all(Radius.circular(999));

  /// Modal sheets are rounded on their top edge only.
  static const brSheetTop = BorderRadius.vertical(top: Radius.circular(card));
}
