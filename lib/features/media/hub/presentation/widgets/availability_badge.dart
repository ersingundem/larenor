import 'package:flutter/cupertino.dart';

import '../../domain/media_title.dart';

/// A small corner mark telling you what you can do with a title at a
/// glance — the one piece of cross-service state that matters while
/// scanning a row.
///
/// Nothing is drawn for a title that's simply in the library: on a
/// Netflix-style page most things are playable, so badging all of them
/// would be noise. The badge marks the exceptions.
class AvailabilityBadge extends StatelessWidget {
  const AvailabilityBadge({super.key, required this.availability});

  final MediaAvailability availability;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (availability) {
      MediaAvailability.inLibrary => (null, null),
      MediaAvailability.downloading => (
        CupertinoIcons.arrow_down_circle_fill,
        CupertinoColors.systemBlue,
      ),
      MediaAvailability.requested => (
        CupertinoIcons.clock_fill,
        CupertinoColors.systemOrange,
      ),
      MediaAvailability.monitored => (
        CupertinoIcons.eye_fill,
        CupertinoColors.systemPurple,
      ),
      MediaAvailability.notAvailable => (
        CupertinoIcons.cloud,
        CupertinoColors.systemGrey,
      ),
    };

    if (icon == null || color == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: CupertinoColors.black.withValues(alpha: 0.55),
        shape: BoxShape.circle,
      ),
      child: Icon(
        icon,
        size: 13,
        color: CupertinoDynamicColor.resolve(color, context),
      ),
    );
  }
}
