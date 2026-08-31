import 'package:flutter/cupertino.dart';

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
    final value = (fraction ?? 0).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label ${(value * 100).round()}%',
          style: TextStyle(
            fontSize: 12,
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
            child: FractionallySizedBox(
              widthFactor: value,
              child: Container(color: CupertinoTheme.of(context).primaryColor),
            ),
          ),
        ),
      ],
    );
  }
}
