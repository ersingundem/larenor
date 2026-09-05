import 'package:flutter/cupertino.dart';

import '../../../../shared/theme/typography.dart';
import '../../../../l10n/generated/app_localizations.dart';

/// A small labeled usage bar (e.g. "CPU 32%") — hand-rolled rather than a
/// Material `LinearProgressIndicator`, matching the pattern already used
/// for playback-progress bars elsewhere in the app.
class ProxmoxUsageBar extends StatelessWidget {
  const ProxmoxUsageBar({
    super.key,
    required this.label,
    required this.fraction,
  });

  final String label;
  final double? fraction;

  @override
  Widget build(BuildContext context) {
    final value =
        fraction != null &&
            fraction!.isFinite &&
            fraction! >= 0 &&
            fraction! <= 1
        ? fraction
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label ${value == null ? AppLocalizations.of(context).commonUnknown : '${(value * 100).round()}%'}',
          style: TextStyle(
            fontSize: AppText.caption1.fontSize,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Container(
            height: 6,
            color: CupertinoColors.systemGrey5.resolveFrom(context),
            alignment: Alignment.centerLeft,
            child: value == null
                ? null
                : FractionallySizedBox(
                    widthFactor: value,
                    child: Container(
                      color: CupertinoTheme.of(context).primaryColor,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
