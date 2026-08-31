import 'package:flutter/cupertino.dart';

/// A small rounded-square colored badge behind a white glyph, matching
/// iOS Settings/Home's list-row icon convention — used instead of a bare
/// colored [Icon] so color reads as per-row categorization, not a flat
/// app-wide accent.
class IconBadge extends StatelessWidget {
  const IconBadge({
    super.key,
    required this.icon,
    required this.color,
    this.size = 29,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: CupertinoDynamicColor.resolve(color, context),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: CupertinoColors.white, size: size * 0.62),
    );
  }
}
