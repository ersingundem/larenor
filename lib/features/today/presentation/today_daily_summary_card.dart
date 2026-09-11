import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../domain/today_daily_summary.dart';

class TodayDailySummaryCard extends StatelessWidget {
  const TodayDailySummaryCard({
    super.key,
    required this.summary,
    this.onPressed,
  });

  final TodayDailySummary summary;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final sections = summary.sections;
    final semantics = <String>[
      l10n.todayTitle,
      for (final section in sections)
        '${_title(l10n, section.kind)}. ${_state(l10n, section)}',
    ].join('. ');
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
              if (onPressed != null)
                const Icon(CupertinoIcons.chevron_forward, size: 18),
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
                      child: _Section(section: section),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
    final action = onPressed == null
        ? content
        : CupertinoButton(
            minimumSize: const Size.square(48),
            padding: EdgeInsets.zero,
            onPressed: onPressed,
            child: content,
          );
    return Semantics(
      key: const ValueKey('today-daily-summary-card'),
      container: true,
      button: onPressed != null,
      enabled: onPressed == null ? null : true,
      label: semantics,
      child: ExcludeSemantics(child: action),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.section});

  final TodayDailySummarySection section;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final warning = switch (section.state) {
      TodayDailySummaryState.current || TodayDailySummaryState.empty => false,
      _ => true,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoColors.tertiarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(14),
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
                    _title(l10n, section.kind),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.headline,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _state(l10n, section),
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
  }
}

String _title(AppLocalizations l10n, TodayDailySummaryKind kind) =>
    switch (kind) {
      TodayDailySummaryKind.shopping => l10n.todaySummaryShopping,
      TodayDailySummaryKind.chores => l10n.todaySummaryChores,
      TodayDailySummaryKind.calendar => l10n.todayCalendar,
      TodayDailySummaryKind.notifications => l10n.todayNotifications,
    };

String _state(AppLocalizations l10n, TodayDailySummarySection section) {
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
