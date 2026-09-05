import 'package:flutter/cupertino.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../domain/media_title.dart';
import 'media_progress_card.dart';

/// Source status is shared with the detail card; a partial title keeps its mark.
class AvailabilityBadge extends StatelessWidget {
  const AvailabilityBadge({super.key, required this.availability});
  final MediaAvailability availability;
  @override
  Widget build(BuildContext context) {
    if (availability == MediaAvailability.inLibrary) {
      return const SizedBox.shrink();
    }
    return Semantics(
      label: mediaAvailabilityLabel(AppLocalizations.of(context), availability),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: CupertinoColors.black.withValues(alpha: 0.55),
          shape: BoxShape.circle,
        ),
        child: Icon(
          mediaAvailabilityIcon(availability),
          size: 13,
          color: CupertinoDynamicColor.resolve(
            mediaAvailabilityColor(availability),
            context,
          ),
        ),
      ),
    );
  }
}
