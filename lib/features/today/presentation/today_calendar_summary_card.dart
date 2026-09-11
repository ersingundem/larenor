import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../navigation/search/domain/local_search_index.dart';
import '../domain/today_calendar_summary.dart';
import 'today_support.dart';

/// Tablet-first, read-only calendar agenda. It exposes local selection and
/// filtering callbacks only; there is no Home Assistant mutation surface.
class TodayCalendarSummaryCard extends StatefulWidget {
  const TodayCalendarSummaryCard({
    super.key,
    required this.summary,
    this.timeZone,
    this.query = '',
    this.selectedSourceId,
    this.selectedItemId,
    this.onQueryChanged,
    this.onItemSelected,
    this.onClose,
  });

  final TodayCalendarSummary summary;
  final String? timeZone;
  final String query;
  final String? selectedSourceId;
  final String? selectedItemId;
  final ValueChanged<String>? onQueryChanged;
  final ValueChanged<TodayCalendarSummaryEntry>? onItemSelected;
  final VoidCallback? onClose;

  @override
  State<TodayCalendarSummaryCard> createState() =>
      _TodayCalendarSummaryCardState();
}

class _TodayCalendarSummaryCardState extends State<TodayCalendarSummaryCard> {
  late final TextEditingController _search = TextEditingController(
    text: widget.query,
  );

  @override
  void didUpdateWidget(TodayCalendarSummaryCard oldWidget) {
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
    final folded = foldSearchText(_search.text);
    final allDay = _filter(widget.summary.allDay, folded);
    final timed = _filter(widget.summary.timed, folded);
    final semantics = <String>[
      l10n.todayCalendar,
      for (final evidence in widget.summary.staleSources)
        l10n.todayCalendarSavedSource(_sourceTitle(l10n, evidence)),
      for (final evidence in widget.summary.unavailableSources)
        l10n.todayCalendarUnavailableSource(_sourceTitle(l10n, evidence)),
    ].join('. ');
    return Semantics(
      key: const ValueKey('today-calendar-summary'),
      container: true,
      explicitChildNodes: true,
      label: semantics,
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
                Expanded(
                  child: Text(l10n.todayCalendar, style: AppText.title3),
                ),
                if (widget.onClose != null)
                  CupertinoButton(
                    key: const ValueKey('today-calendar-close'),
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
            for (final evidence in widget.summary.staleSources)
              _evidence(
                context,
                l10n.todayCalendarSavedSource(_sourceTitle(l10n, evidence)),
                todayFailureLabel(l10n, evidence.failure),
                CupertinoColors.systemOrange,
              ),
            for (final evidence in widget.summary.unavailableSources)
              _evidence(
                context,
                l10n.todayCalendarUnavailableSource(
                  _sourceTitle(l10n, evidence),
                ),
                todayFailureLabel(l10n, evidence.failure),
                CupertinoColors.systemRed,
              ),
            if (widget.summary.allDay.isNotEmpty ||
                widget.summary.timed.isNotEmpty ||
                _search.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: CupertinoSearchTextField(
                  key: const ValueKey('today-calendar-search'),
                  controller: _search,
                  placeholder: l10n.commonSearch,
                  onChanged: _changeQuery,
                ),
              ),
            if (allDay.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(l10n.todayCalendarAllDayEvents, style: AppText.headline),
              for (final entry in allDay) _entry(context, entry),
            ],
            if (timed.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(l10n.todayCalendarTimedEvents, style: AppText.headline),
              for (final entry in timed) _entry(context, entry),
            ],
            if (allDay.isEmpty && timed.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  folded.isEmpty
                      ? l10n.todayNoEvents
                      : l10n.navigationSearchEmpty,
                  style: AppText.body,
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<TodayCalendarSummaryEntry> _filter(
    List<TodayCalendarSummaryEntry> entries,
    String query,
  ) => entries
      .where(
        (entry) =>
            query.isEmpty ||
            foldSearchText(
              '${entry.event.title} ${entry.sourceTitle} '
              '${entry.event.location ?? ''} '
              '${entry.event.description ?? ''}',
            ).contains(query),
      )
      .toList(growable: false);

  void _changeQuery(String value) {
    final clean = value
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
        .characters
        .take(128)
        .toString();
    if (clean != value) {
      _search.value = TextEditingValue(
        text: clean,
        selection: TextSelection.collapsed(offset: clean.length),
      );
    }
    setState(() {});
    widget.onQueryChanged?.call(clean);
  }

  Widget _evidence(
    BuildContext context,
    String title,
    String detail,
    CupertinoDynamicColor color,
  ) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Semantics(
      label: '$title. $detail',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.resolveFrom(context).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppText.headline),
              Text(detail, style: AppText.footnote),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _entry(BuildContext context, TodayCalendarSummaryEntry entry) {
    final l10n = AppLocalizations.of(context);
    final uid = entry.event.uid;
    final selectable = uid != null && widget.onItemSelected != null;
    final selected =
        selectable &&
        widget.selectedSourceId == entry.sourceId &&
        widget.selectedItemId == uid;
    final phase = switch (entry.phase) {
      TodayCalendarPhase.past => l10n.todayCalendarPast,
      TodayCalendarPhase.current => l10n.todayCalendarCurrent,
      TodayCalendarPhase.upcoming => l10n.todayCalendarUpcoming,
    };
    final evidence = entry.stale ? l10n.todayCalendarSaved : null;
    final label = [
      entry.event.title,
      entry.sourceTitle,
      phase,
      todayEventTime(context, entry.event, timeZone: widget.timeZone),
      ?entry.event.location,
      ?evidence,
    ].join('. ');
    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          entry.event.allDay ? CupertinoIcons.calendar : CupertinoIcons.clock,
          size: 20,
          color: CupertinoTheme.of(context).primaryColor,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.event.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.body,
              ),
              Text(
                todayEventTime(context, entry.event, timeZone: widget.timeZone),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.footnote,
              ),
              Text(entry.sourceTitle, style: AppText.footnote),
              if (entry.event.location?.isNotEmpty == true)
                Text(
                  entry.event.location!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.footnote,
                ),
              if (entry.event.description?.isNotEmpty == true)
                Text(
                  entry.event.description!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.footnote,
                ),
              Wrap(
                spacing: 8,
                children: [
                  Text(phase, style: AppText.footnote),
                  if (evidence != null) Text(evidence, style: AppText.footnote),
                ],
              ),
            ],
          ),
        ),
      ],
    );
    if (!selectable) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: content,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Semantics(
        key: ValueKey('today-calendar-event-${entry.sourceId}-$uid'),
        button: true,
        selected: selected,
        label: label,
        child: CupertinoButton(
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

  String _sourceTitle(
    AppLocalizations l10n,
    TodayCalendarSourceEvidence evidence,
  ) => evidence.sourceTitle.isEmpty ? l10n.todayCalendar : evidence.sourceTitle;
}
