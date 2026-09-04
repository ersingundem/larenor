import 'package:flutter/cupertino.dart';

/// One adaptive palette for Home, media, settings and service screens.
abstract final class AppColors {
  static const canvas = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFF3EDE6),
    darkColor: Color(0xFF202C36),
  );
  static const mist = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFE7EEEE),
    darkColor: Color(0xFF192B35),
  );
  static const dusk = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFEAE8F1),
    darkColor: Color(0xFF282735),
  );
  static const surface = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFFDFDFD),
    darkColor: Color(0xFF2B333E),
  );
  static const navigation = CupertinoDynamicColor.withBrightness(
    color: Color(0xDAF4F0EB),
    darkColor: Color(0xDA202C36),
  );
}
