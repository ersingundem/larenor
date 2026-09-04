import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../data/models/arr_calendar_item.dart';
import '../../data/models/arr_queue_item.dart';
import '../../../../../shared/theme/spacing.dart';
import '../../../../../shared/widgets/section_header.dart';

/// Shared read-only monitoring view — active download queue with progress,
/// plus the upcoming-release calendar. Identical shape for Sonarr and
/// Radarr; only the underlying data differs.
class ArrDashboardBody extends StatelessWidget {
  const ArrDashboardBody({
    super.key,
    required this.queue,
    required this.calendar,
  });

  final AsyncValue<List<ArrQueueItem>> queue;
  final AsyncValue<List<ArrCalendarItem>> calendar;

  /// The same content as [build], as slivers — so a caller can put it
  /// under a large title, which has to live in the scroll view itself.
  List<Widget> slivers(BuildContext context) => [
    SliverList(delegate: SliverChildListDelegate(_sections(context))),
  ];

  @override
  Widget build(BuildContext context) => ListView(children: _sections(context));

  List<Widget> _sections(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return [
      const SizedBox(height: Gap.sm),
      _Section(
        title: l10n.arrDownloadQueueHeader,
        items: queue,
        empty: l10n.arrNothingDownloading,
        builder: (item) => CupertinoListTile(
          title: Text(item.title),
          subtitle: Text(item.status),
          additionalInfo: item.progressFraction != null
              ? Text('${(item.progressFraction! * 100).round()}%')
              : (item.timeLeft != null ? Text(item.timeLeft!) : null),
        ),
      ),
      _Section(
        title: l10n.arrUpcomingHeader,
        items: calendar,
        empty: l10n.arrNothingScheduled,
        builder: (item) => CupertinoListTile(
          title: Text(item.title),
          subtitle: item.subtitle != null ? Text(item.subtitle!) : null,
          additionalInfo: item.date != null
              ? Text(_formatDate(item.date!))
              : null,
        ),
      ),
    ];
  }

  String _formatDate(DateTime date) =>
      '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
}

class _Section<T> extends StatelessWidget {
  const _Section({
    required this.title,
    required this.items,
    required this.empty,
    required this.builder,
  });

  final String title;
  final AsyncValue<List<T>> items;
  final String empty;
  final Widget Function(T item) builder;

  @override
  Widget build(BuildContext context) {
    final data = items.value ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        if (items.isLoading && data.isEmpty)
          const Center(child: CupertinoActivityIndicator())
        else if (data.isEmpty)
          Padding(padding: Insets.page, child: Text(empty))
        else
          CupertinoListSection.insetGrouped(
            children: [for (final item in data) builder(item)],
          ),
      ],
    );
  }
}
