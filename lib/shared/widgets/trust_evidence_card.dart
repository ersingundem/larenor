import 'package:flutter/cupertino.dart';

import '../theme/typography.dart';

enum TrustEvidenceState { checking, verified, actionRequired }

/// A consistent, text-first trust surface for tablet and desktop layouts.
/// Color reinforces the icon and copy but never carries the status alone.
class TrustEvidenceCard extends StatelessWidget {
  const TrustEvidenceCard({
    super.key,
    required this.state,
    required this.title,
    required this.body,
    this.detail,
    this.actionKey,
    this.actionLabel,
    this.onAction,
  }) : assert(onAction == null || actionLabel != null);

  final TrustEvidenceState state;
  final String title, body;
  final String? detail, actionLabel;
  final Key? actionKey;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      TrustEvidenceState.checking => CupertinoColors.systemBlue,
      TrustEvidenceState.verified => CupertinoColors.systemGreen,
      TrustEvidenceState.actionRequired => CupertinoColors.systemOrange,
    };
    final icon = switch (state) {
      TrustEvidenceState.checking =>
        CupertinoIcons.arrow_2_circlepath_circle_fill,
      TrustEvidenceState.verified => CupertinoIcons.checkmark_shield_fill,
      TrustEvidenceState.actionRequired =>
        CupertinoIcons.exclamationmark_shield_fill,
    };
    final resolved = color.resolveFrom(context);
    final semantics = [title, body, ?detail].join('. ');
    return Semantics(
      container: true,
      explicitChildNodes: true,
      liveRegion: true,
      label: semantics,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: resolved.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: CupertinoColors.separator.resolveFrom(context),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExcludeSemantics(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(icon, size: 24, color: resolved),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: AppText.headline.copyWith(color: resolved),
                          ),
                          const SizedBox(height: 4),
                          Text(body, style: AppText.body),
                          if (detail != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              detail!,
                              style: AppText.footnote.copyWith(
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (actionLabel != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: CupertinoButton.tinted(
                    key: actionKey,
                    minimumSize: const Size(44, 44),
                    focusColor: CupertinoTheme.of(context).primaryColor,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    onPressed: onAction,
                    child: Text(actionLabel!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
