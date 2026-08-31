import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/arr_calendar_item.dart';
import '../../data/models/arr_queue_item.dart';

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

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 16),
        _Section(
          title: 'DOWNLOAD QUEUE',
          items: queue,
          empty: 'Nothing downloading',
          builder: (item) => CupertinoListTile(
            title: Text(item.title),
            subtitle: Text(item.status),
            additionalInfo: item.progressFraction != null
                ? Text('${(item.progressFraction! * 100).round()}%')
                : (item.timeLeft != null ? Text(item.timeLeft!) : null),
          ),
        ),
        _Section(
          title: 'UPCOMING',
          items: calendar,
          empty: 'Nothing scheduled',
          builder: (item) => CupertinoListTile(
            title: Text(item.title),
            subtitle: item.subtitle != null ? Text(item.subtitle!) : null,
            additionalInfo: item.date != null
                ? Text(_formatDate(item.date!))
                : null,
          ),
        ),
      ],
    );
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
        ),
        if (items.isLoading && data.isEmpty)
          const Center(child: CupertinoActivityIndicator())
        else if (data.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(empty),
          )
        else
          CupertinoListSection.insetGrouped(
            children: [for (final item in data) builder(item)],
          ),
      ],
    );
  }
}
