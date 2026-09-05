import 'package:flutter/cupertino.dart';

/// A settings action with native keyboard activation and one button semantics
/// node. Switches and other independently interactive controls remain separate.
class SettingsActionTile extends StatelessWidget {
  const SettingsActionTile({
    super.key,
    required this.title,
    required this.onTap,
    this.leading,
    this.additionalInfo,
    this.selected,
  });

  final Widget title;
  final Widget? leading;
  final Widget? additionalInfo;
  final bool? selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = CupertinoTheme.of(context);
    final foreground =
        (onTap == null ? CupertinoColors.tertiaryLabel : CupertinoColors.label)
            .resolveFrom(context);
    return Semantics(
      enabled: onTap != null,
      selected: selected,
      // CupertinoButton paints its focus outline outside the button. Keep it
      // inside the list section's clip, including the first and last rows.
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: CupertinoButton(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 10, 6),
          borderRadius: BorderRadius.circular(6),
          focusColor: theme.primaryColor,
          alignment: AlignmentDirectional.centerStart,
          onPressed: onTap,
          child: IconTheme.merge(
            data: IconThemeData(color: foreground),
            child: Row(
              children: [
                if (leading case final leading?) ...[
                  ExcludeSemantics(
                    child: SizedBox.square(dimension: 28, child: leading),
                  ),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  child: DefaultTextStyle(
                    style: theme.textTheme.textStyle.copyWith(
                      color: foreground,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        title,
                        if (additionalInfo case final additionalInfo?) ...[
                          const SizedBox(height: 4),
                          DefaultTextStyle(
                            style: theme.textTheme.textStyle.copyWith(
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                            child: additionalInfo,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                const ExcludeSemantics(child: CupertinoListTileChevron()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
