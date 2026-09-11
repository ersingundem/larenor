import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../domain/today_daily_summary.dart';
import 'today_daily_summary_card.dart';

/// A bounded read-only companion for the tablet summary master. It renders only
/// normalized summary data and never owns a Home Assistant action.
class TodaySummaryDetailCard extends StatelessWidget {
  const TodaySummaryDetailCard({
    super.key,
    required this.section,
    this.onOpen,
    this.onClose,
  });

  static const maximumEntries = 8;
  final TodayDailySummarySection section;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = todaySummaryTitle(l10n, section.kind);
    final state = todaySummaryStateLabel(l10n, section);
    final entries = section.entries
        .take(maximumEntries)
        .toList(growable: false);
    final canOpen = onOpen != null && todaySummarySectionNavigable(section);
    final warning = switch (section.state) {
      TodayDailySummaryState.current || TodayDailySummaryState.empty => false,
      _ => true,
    };
    return Semantics(
      key: ValueKey('today-summary-detail-${section.kind.name}'),
      container: true,
      explicitChildNodes: true,
      label: '$title. $state',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
            context,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: AppText.title3)),
                if (onClose != null)
                  CupertinoButton(
                    key: const ValueKey('today-summary-detail-close'),
                    minimumSize: const Size.square(48),
                    padding: EdgeInsets.zero,
                    onPressed: onClose,
                    child: Semantics(
                      button: true,
                      label: l10n.commonClose,
                      child: const ExcludeSemantics(
                        child: Icon(CupertinoIcons.xmark_circle_fill),
                      ),
                    ),
                  ),
              ],
            ),
            Text(
              state,
              style: AppText.footnote.copyWith(
                color: warning
                    ? CupertinoColors.systemOrange.resolveFrom(context)
                    : CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
            for (final entry in entries)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _icon(section.kind),
                      size: 18,
                      color: CupertinoTheme.of(context).primaryColor,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        entry.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body,
                      ),
                    ),
                  ],
                ),
              ),
            if (canOpen)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: CupertinoButton(
                  key: const ValueKey('today-summary-detail-open'),
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  onPressed: onOpen,
                  child: Text(
                    l10n.todayViewAll(
                      section.totalCount ?? section.entries.length,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

IconData _icon(TodayDailySummaryKind kind) => switch (kind) {
  TodayDailySummaryKind.shopping => CupertinoIcons.cart,
  TodayDailySummaryKind.chores => CupertinoIcons.check_mark_circled,
  TodayDailySummaryKind.calendar => CupertinoIcons.calendar,
  TodayDailySummaryKind.notifications => CupertinoIcons.bell,
};
