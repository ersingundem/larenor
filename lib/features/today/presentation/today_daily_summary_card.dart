import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../domain/today_daily_summary.dart';

class TodayDailySummaryCard extends StatelessWidget {
  const TodayDailySummaryCard({
    super.key,
    required this.summary,
    this.onSectionPressed,
    this.selectedKind,
  });

  final TodayDailySummary summary;
  final ValueChanged<TodayDailySummaryKind>? onSectionPressed;
  final TodayDailySummaryKind? selectedKind;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final sections = summary.sections;
    final content = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
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
              Icon(
                CupertinoIcons.calendar_today,
                size: 20,
                color: CupertinoTheme.of(context).primaryColor,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(l10n.todayTitle, style: AppText.title3)),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final scale = MediaQuery.textScalerOf(context).scale(1);
              final columns = scale >= 1.8
                  ? (constraints.maxWidth >= 1000 ? 2 : 1)
                  : (constraints.maxWidth >= 1000 ? 4 : 2);
              const spacing = 10.0;
              final width =
                  (constraints.maxWidth - spacing * (columns - 1)) / columns;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final section in sections)
                    SizedBox(
                      width: width,
                      child: _Section(
                        section: section,
                        selected: section.kind == selectedKind,
                        onPressed: onSectionPressed == null
                            ? null
                            : () => onSectionPressed!(section.kind),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
    return Semantics(
      key: const ValueKey('today-daily-summary-card'),
      container: true,
      explicitChildNodes: true,
      child: content,
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.section,
    required this.selected,
    this.onPressed,
  });

  final TodayDailySummarySection section;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final warning = switch (section.state) {
      TodayDailySummaryState.current || TodayDailySummaryState.empty => false,
      _ => true,
    };
    final enabled = onPressed != null && todaySummarySectionNavigable(section);
    final isSelected = selected && enabled;
    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoColors.tertiarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(14),
        border: isSelected
            ? Border.all(
                color: CupertinoTheme.of(context).primaryColor,
                width: 2,
              )
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _icon(section.kind),
                  size: 18,
                  color: CupertinoTheme.of(context).primaryColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    todaySummaryTitle(l10n, section.kind),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.headline,
                  ),
                ),
                if (enabled)
                  const Icon(CupertinoIcons.chevron_forward, size: 16),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              todaySummaryStateLabel(l10n, section),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.footnote.copyWith(
                color: warning
                    ? CupertinoColors.systemOrange.resolveFrom(context)
                    : CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ),
      ),
    );
    return Semantics(
      key: ValueKey('today-summary-section-${section.kind.name}'),
      button: true,
      enabled: enabled,
      selected: isSelected,
      label:
          '${todaySummaryTitle(l10n, section.kind)}. '
          '${todaySummaryStateLabel(l10n, section)}',
      child: ExcludeSemantics(
        child: CupertinoButton(
          minimumSize: const Size.square(48),
          padding: EdgeInsets.zero,
          onPressed: enabled ? onPressed : null,
          child: content,
        ),
      ),
    );
  }
}

bool todaySummarySectionNavigable(TodayDailySummarySection section) =>
    switch (section.state) {
      TodayDailySummaryState.current ||
      TodayDailySummaryState.partial ||
      TodayDailySummaryState.stale =>
        section.totalCount != null || section.entries.isNotEmpty,
      TodayDailySummaryState.unread ||
      TodayDailySummaryState.empty ||
      TodayDailySummaryState.offline ||
      TodayDailySummaryState.denied ||
      TodayDailySummaryState.unsupported ||
      TodayDailySummaryState.error => false,
    };

String todaySummaryTitle(AppLocalizations l10n, TodayDailySummaryKind kind) =>
    switch (kind) {
      TodayDailySummaryKind.shopping => l10n.todaySummaryShopping,
      TodayDailySummaryKind.chores => l10n.todaySummaryChores,
      TodayDailySummaryKind.calendar => l10n.todayCalendar,
      TodayDailySummaryKind.notifications => l10n.todayNotifications,
    };

String todaySummaryStateLabel(
  AppLocalizations l10n,
  TodayDailySummarySection section,
) {
  final count = section.totalCount;
  return switch (section.state) {
    TodayDailySummaryState.current => l10n.todaySummaryOpen(count!),
    TodayDailySummaryState.empty => l10n.todaySummaryNothingDue,
    TodayDailySummaryState.stale =>
      count == null
          ? l10n.todaySummarySavedViewUnknown
          : l10n.todaySummarySavedView(count),
    TodayDailySummaryState.partial => l10n.todaySummaryPartial,
    TodayDailySummaryState.offline => l10n.todaySummaryOffline,
    TodayDailySummaryState.denied => l10n.todaySummaryDenied,
    TodayDailySummaryState.unsupported => l10n.todaySummaryUnsupported,
    TodayDailySummaryState.error => l10n.todaySummaryReadFailed,
    TodayDailySummaryState.unread => l10n.todaySummaryAwaitingSource,
  };
}

IconData _icon(TodayDailySummaryKind kind) => switch (kind) {
  TodayDailySummaryKind.shopping => CupertinoIcons.cart,
  TodayDailySummaryKind.chores => CupertinoIcons.check_mark_circled,
  TodayDailySummaryKind.calendar => CupertinoIcons.calendar,
  TodayDailySummaryKind.notifications => CupertinoIcons.bell,
};
