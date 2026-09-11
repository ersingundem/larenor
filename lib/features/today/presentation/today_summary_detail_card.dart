import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../navigation/search/domain/local_search_index.dart';
import '../domain/today_daily_summary.dart';
import 'today_daily_summary_card.dart';

/// A bounded read-only companion for the tablet summary master. It renders only
/// normalized summary data and never owns a Home Assistant action.
class TodaySummaryDetailCard extends StatefulWidget {
  const TodaySummaryDetailCard({
    super.key,
    required this.section,
    this.query = '',
    this.onQueryChanged,
    this.selectedSourceId,
    this.selectedItemId,
    this.onItemSelected,
    this.onOpen,
    this.onClose,
  });

  static const maximumEntries = 8;
  final TodayDailySummarySection section;
  final String query;
  final ValueChanged<String>? onQueryChanged;
  final String? selectedSourceId;
  final String? selectedItemId;
  final ValueChanged<TodayDailySummaryEntry>? onItemSelected;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;

  @override
  State<TodaySummaryDetailCard> createState() => _TodaySummaryDetailCardState();
}

class _TodaySummaryDetailCardState extends State<TodaySummaryDetailCard> {
  late final TextEditingController _search = TextEditingController(
    text: widget.query,
  );

  @override
  void didUpdateWidget(TodaySummaryDetailCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != oldWidget.query && _search.text != widget.query) {
      _search.value = TextEditingValue(
        text: widget.query,
        selection: TextSelection.collapsed(offset: widget.query.length),
      );
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = todaySummaryTitle(l10n, widget.section.kind);
    final state = todaySummaryStateLabel(l10n, widget.section);
    final foldedQuery = foldSearchText(_search.text);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final maximumEntries = textScale >= 1.8
        ? 5
        : TodaySummaryDetailCard.maximumEntries;
    final entries = widget.section.entries
        .where((entry) {
          if (foldedQuery.isEmpty) return true;
          return foldSearchText('${entry.title} ${entry.supportingText ?? ''}')
              .contains(foldedQuery);
        })
        .take(maximumEntries)
        .toList(growable: false);
    final canOpen =
        widget.onOpen != null && todaySummarySectionNavigable(widget.section);
    final warning = switch (widget.section.state) {
      TodayDailySummaryState.current || TodayDailySummaryState.empty => false,
      _ => true,
    };
    return Semantics(
      key: ValueKey('today-summary-detail-${widget.section.kind.name}'),
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
                if (widget.onClose != null)
                  CupertinoButton(
                    key: const ValueKey('today-summary-detail-close'),
                    minimumSize: const Size.square(48),
                    padding: EdgeInsets.zero,
                    onPressed: widget.onClose,
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
            if (canOpen)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: CupertinoButton(
                  key: const ValueKey('today-summary-detail-open'),
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  onPressed: widget.onOpen,
                  child: Text(
                    l10n.todayViewAll(
                      widget.section.totalCount ??
                          widget.section.entries.length,
                    ),
                  ),
                ),
              ),
            if (widget.section.entries.isNotEmpty || _search.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: CupertinoSearchTextField(
                  key: const ValueKey('today-summary-detail-search'),
                  controller: _search,
                  placeholder: l10n.commonSearch,
                  onChanged: (value) {
                    final clean = value
                        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
                        .characters
                        .take(128)
                        .toString();
                    if (clean != value) {
                      _search.value = TextEditingValue(
                        text: clean,
                        selection: TextSelection.collapsed(
                          offset: clean.length,
                        ),
                      );
                    }
                    setState(() {});
                    widget.onQueryChanged?.call(clean);
                  },
                ),
              ),
            if (entries.isEmpty && foldedQuery.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(l10n.navigationSearchEmpty, style: AppText.body),
              ),
            for (final entry in entries) _entry(context, entry),
          ],
        ),
      ),
    );
  }

  Widget _entry(BuildContext context, TodayDailySummaryEntry entry) {
    final selectable = entry.itemId != null && widget.onItemSelected != null;
    final selected =
        selectable &&
        widget.selectedSourceId == entry.sourceId &&
        widget.selectedItemId == entry.itemId;
    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          _icon(widget.section.kind),
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
    );
    if (!selectable) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Align(alignment: Alignment.centerLeft, child: content),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Semantics(
        button: true,
        selected: selected,
        label: entry.title,
        child: CupertinoButton(
          key: ValueKey(
            'today-summary-detail-item-${entry.sourceId}-${entry.itemId}',
          ),
          minimumSize: const Size(double.infinity, 48),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          color: selected
              ? CupertinoTheme.of(context).primaryColor.withValues(alpha: 0.12)
              : null,
          borderRadius: BorderRadius.circular(12),
          onPressed: () => widget.onItemSelected!(entry),
          child: ExcludeSemantics(child: content),
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
