import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../data/media_archive_health_controller.dart';
import '../domain/media_archive_health.dart';
import 'media_archive_health_detail_screen.dart';

final class MediaArchiveHealthCard extends StatelessWidget {
  const MediaArchiveHealthCard({super.key, required this.controller});
  final MediaArchiveHealthController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final status = _status(l, controller.state);
      return Semantics(
        container: true,
        explicitChildNodes: true,
        label: '${l.mediaArchiveTitle}. $status',
        child: Container(
          key: const ValueKey('media-archive-health-card'),
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
              context,
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: CupertinoColors.separator.resolveFrom(context),
              width: 0.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(
                            l.mediaArchiveTitle,
                            style: AppText.headline,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(l.mediaArchiveReadOnly, style: AppText.footnote),
                      ],
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: l.mediaArchiveRefreshLabel,
                    child: ExcludeSemantics(
                      child: CupertinoButton(
                        key: const ValueKey('media-archive-refresh'),
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        onPressed: controller.canRefresh
                            ? () => unawaited(controller.refresh())
                            : null,
                        child: const Icon(CupertinoIcons.refresh, size: 20),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (controller.state == MediaArchiveCardState.loading) ...[
                      const CupertinoActivityIndicator(),
                      const SizedBox(width: 10),
                    ],
                    Expanded(child: Text(status, style: AppText.body)),
                  ],
                ),
              ),
              if (controller.snapshot case final snapshot?) ...[
                const SizedBox(height: 14),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 900 ? 5 : 2;
                    final width =
                        (constraints.maxWidth - (columns - 1) * 10) / columns;
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _metric(
                          l.mediaArchiveMissing,
                          '${snapshot.counts.missing}',
                          width,
                        ),
                        _metric(
                          l.mediaArchiveBroken,
                          '${snapshot.counts.broken}',
                          width,
                        ),
                        _metric(
                          l.mediaArchiveFailedDownloads,
                          '${snapshot.counts.failedDownloads}',
                          width,
                        ),
                        _metric(
                          l.mediaArchiveSavingCandidates,
                          '${snapshot.counts.savingCandidates}',
                          width,
                        ),
                        _metric(
                          l.mediaArchivePotentialSavings,
                          _bytes(snapshot.counts.potentialSavingBytes),
                          width,
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in snapshot.sourceStates.entries)
                      Semantics(
                        label: '${entry.key}, ${_source(l, entry.value)}',
                        child: ExcludeSemantics(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: CupertinoColors.tertiarySystemFill
                                  .resolveFrom(context),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              child: Text(
                                '${entry.key} · ${_source(l, entry.value)}',
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                _weeklyTrend(context, l, snapshot.weeklyTrend),
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: CupertinoButton(
                    key: const ValueKey('media-archive-details'),
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    onPressed: () {
                      if (!identical(controller.snapshot, snapshot)) return;
                      Navigator.of(context).push(
                        CupertinoPageRoute<void>(
                          builder: (_) => MediaArchiveHealthDetailScreen(
                            snapshot: snapshot,
                          ),
                        ),
                      );
                    },
                    child: Text(l.mediaArchiveOpenDetails),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );

  static Widget _metric(String label, String value, double width) => Semantics(
    label: '$label, $value',
    child: ExcludeSemantics(
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: AppText.headline),
              const SizedBox(height: 3),
              Text(label, style: AppText.footnote),
            ],
          ),
        ),
      ),
    ),
  );

  static Widget _weeklyTrend(
    BuildContext context,
    AppLocalizations l,
    MediaArchiveWeeklyTrend trend,
  ) {
    final status = switch (trend.state) {
      MediaArchiveWeeklyTrendState.ready => l.mediaArchiveTrendReady,
      MediaArchiveWeeklyTrendState.stale => l.mediaArchiveTrendStale,
      MediaArchiveWeeklyTrendState.unavailable =>
        l.mediaArchiveTrendUnavailable,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(l.mediaArchiveTrendTitle, style: AppText.body),
        ),
        const SizedBox(height: 4),
        Text(status, style: AppText.footnote),
        if (trend.points.isNotEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(
            key: const ValueKey('media-archive-weekly-trend'),
            height: 104,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final point in trend.points)
                  Expanded(child: _trendBar(context, l, point)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              Text(l.mediaArchiveTrendFree, style: AppText.footnote),
              Text(l.mediaArchiveTrendReclaimable, style: AppText.footnote),
              Text(l.mediaArchiveTrendCandidateCounts, style: AppText.footnote),
            ],
          ),
        ],
      ],
    );
  }

  static Widget _trendBar(
    BuildContext context,
    AppLocalizations l,
    MediaArchiveWeeklyTrendPoint point,
  ) {
    final freeRatio = point.freeBytes / point.totalBytes;
    final reclaimRatio = point.reclaimableBytes / point.totalBytes;
    final date =
        '${point.weekStart.year.toString().padLeft(4, '0')}-'
        '${point.weekStart.month.toString().padLeft(2, '0')}-'
        '${point.weekStart.day.toString().padLeft(2, '0')}';
    final label =
        '${l.mediaArchiveTrendWeek(date)}, '
        '${l.mediaArchiveTrendTotal}: ${_bytes(point.totalBytes)}, '
        '${l.mediaArchiveTrendFree}: ${_bytes(point.freeBytes)}, '
        '${l.mediaArchiveTrendReclaimable}: ${_bytes(point.reclaimableBytes)}, '
        '${l.mediaArchiveTrendDuplicates}: ${point.duplicateCandidates}, '
        '${l.mediaArchiveTrendLowQuality}: ${point.lowQualityCandidates}';
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              Container(
                height: 96,
                decoration: BoxDecoration(
                  color: CupertinoColors.tertiarySystemFill.resolveFrom(
                    context,
                  ),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              Container(
                height: 96 * freeRatio,
                decoration: BoxDecoration(
                  color: CupertinoColors.activeBlue.resolveFrom(context),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              if (reclaimRatio > 0)
                Container(
                  height: (96 * reclaimRatio).clamp(2, 96),
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemOrange.resolveFrom(context),
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _status(AppLocalizations l, MediaArchiveCardState state) =>
      switch (state) {
        MediaArchiveCardState.idle => l.mediaArchiveIdle,
        MediaArchiveCardState.loading => l.mediaArchiveLoading,
        MediaArchiveCardState.healthy => l.mediaArchiveHealthy,
        MediaArchiveCardState.attention => l.mediaArchiveAttention,
        MediaArchiveCardState.partial => l.mediaArchivePartial,
        MediaArchiveCardState.stale => l.mediaArchiveStale,
        MediaArchiveCardState.offline => l.mediaArchiveOffline,
        MediaArchiveCardState.denied => l.mediaArchiveDenied,
        MediaArchiveCardState.unsupported => l.mediaArchiveUnsupported,
      };

  static String _source(AppLocalizations l, MediaArchiveSourceState state) =>
      switch (state) {
        MediaArchiveSourceState.verified => l.mediaArchiveSourceVerified,
        MediaArchiveSourceState.unavailable => l.mediaArchiveSourceUnavailable,
        MediaArchiveSourceState.unsupported => l.mediaArchiveSourceUnsupported,
        MediaArchiveSourceState.stale => l.mediaArchiveSourceStale,
      };

  static String _bytes(int value) {
    if (value >= 1000000000) {
      return '${(value / 1000000000).toStringAsFixed(1)} GB';
    }
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)} MB';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)} KB';
    return '$value B';
  }
}
