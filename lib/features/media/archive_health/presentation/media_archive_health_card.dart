import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../data/media_archive_health_controller.dart';
import '../domain/media_archive_health.dart';

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
