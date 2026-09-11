import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../domain/media_archive_health.dart';

final class MediaArchiveSavingsCandidateScreen extends StatelessWidget {
  const MediaArchiveSavingsCandidateScreen({
    super.key,
    required this.candidate,
    required this.dataGaps,
  });

  final MediaArchiveSavingsCandidate candidate;
  final List<MediaArchiveSavingsDataGap> dataGaps;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final comparison = candidate.comparison;
    return AppPageScaffold(
      child: CustomScrollView(
        key: const PageStorageKey('media-archive-saving-comparison-scroll'),
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l.mediaArchiveComparisonTitle),
            leading: CupertinoButton(
              key: const ValueKey('media-archive-saving-comparison-back'),
              minimumSize: const Size(48, 48),
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Icon(CupertinoIcons.back),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(candidate.title, style: AppText.title2),
                  ),
                  const SizedBox(height: 8),
                  Semantics(
                    liveRegion: true,
                    label: _confidence(l, candidate.confidence),
                    child: ExcludeSemantics(
                      child: _Pill(label: _confidence(l, candidate.confidence)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    l.mediaArchiveComparisonReadOnly,
                    style: AppText.footnote,
                  ),
                  const SizedBox(height: 20),
                  _MetricGrid(
                    children: [
                      _Metric(
                        label: l.mediaArchiveObservedSize(
                          _bytes(comparison.observedBytes),
                        ),
                      ),
                      _Metric(
                        label: l.mediaArchiveEstimatedRetained(
                          _bytes(comparison.estimatedRetainedBytes),
                        ),
                      ),
                      _Metric(
                        label: l.mediaArchiveEstimatedGain(
                          _bytes(comparison.estimatedSavingBytes),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Semantics(
                    header: true,
                    child: Text(
                      l.mediaArchiveComparisonBasisTitle,
                      style: AppText.headline,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(_basis(l, comparison.basis), style: AppText.body),
                  const SizedBox(height: 24),
                  Semantics(
                    header: true,
                    child: Text(
                      l.mediaArchiveEvidenceTitle,
                      style: AppText.headline,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final evidence in candidate.evidence)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('• ${_evidence(l, evidence)}'),
                    ),
                  if (dataGaps.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Semantics(
                      header: true,
                      child: Text(
                        l.mediaArchiveDataGapsTitle,
                        style: AppText.headline,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final gap in dataGaps)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          l.mediaArchiveDataGap(
                            _kind(l, gap.lane),
                            _gapReason(l, gap.reason),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _confidence(
    AppLocalizations l,
    MediaArchiveSavingConfidence confidence,
  ) => switch (confidence) {
    MediaArchiveSavingConfidence.high => l.mediaArchiveConfidenceHigh,
    MediaArchiveSavingConfidence.medium => l.mediaArchiveConfidenceMedium,
  };

  static String _basis(
    AppLocalizations l,
    MediaArchiveSavingComparisonBasis basis,
  ) => switch (basis) {
    MediaArchiveSavingComparisonBasis.keepLargestCopy =>
      l.mediaArchiveComparisonKeepLargest,
    MediaArchiveSavingComparisonBasis.boundedTranscodeEstimate =>
      l.mediaArchiveComparisonTranscode,
    MediaArchiveSavingComparisonBasis.reviewRetainedCopy =>
      l.mediaArchiveComparisonRetention,
  };

  static String _evidence(
    AppLocalizations l,
    MediaArchiveSavingEvidence evidence,
  ) => switch (evidence) {
    MediaArchiveSavingEvidence.sameMediaIdentity =>
      l.mediaArchiveEvidenceSameIdentity,
    MediaArchiveSavingEvidence.multiplePlayableFiles =>
      l.mediaArchiveEvidenceMultiplePlayable,
    MediaArchiveSavingEvidence.largestCopyExcluded =>
      l.mediaArchiveEvidenceLargestExcluded,
    MediaArchiveSavingEvidence.sourceProfileVerified =>
      l.mediaArchiveEvidenceSourceProfile,
    MediaArchiveSavingEvidence.targetPlaybackVerified =>
      l.mediaArchiveEvidenceTargetPlayback,
    MediaArchiveSavingEvidence.boundedSizeEstimate =>
      l.mediaArchiveEvidenceBoundedEstimate,
    MediaArchiveSavingEvidence.downloadComplete =>
      l.mediaArchiveEvidenceDownloadComplete,
    MediaArchiveSavingEvidence.importVerified =>
      l.mediaArchiveEvidenceImportVerified,
    MediaArchiveSavingEvidence.retentionPolicySatisfied =>
      l.mediaArchiveEvidenceRetentionSatisfied,
  };

  static String _kind(AppLocalizations l, MediaArchiveSavingKind kind) =>
      switch (kind) {
        MediaArchiveSavingKind.duplicate => l.mediaArchivePlanDuplicates,
        MediaArchiveSavingKind.transcode => l.mediaArchivePlanTranscode,
        MediaArchiveSavingKind.retention => l.mediaArchivePlanRetention,
      };

  static String _gapReason(
    AppLocalizations l,
    MediaArchiveSavingGapReason reason,
  ) => switch (reason) {
    MediaArchiveSavingGapReason.partial => l.mediaArchiveGapPartial,
    MediaArchiveSavingGapReason.unsupported => l.mediaArchiveGapUnsupported,
    MediaArchiveSavingGapReason.unavailable => l.mediaArchiveGapUnavailable,
    MediaArchiveSavingGapReason.stale => l.mediaArchiveGapStale,
    MediaArchiveSavingGapReason.truncated => l.mediaArchiveGapTruncated,
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

final class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 900 ? 3 : 1;
      final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}

final class _Metric extends StatelessWidget {
  const _Metric({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
            context,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: CupertinoColors.separator.resolveFrom(context),
            width: 0.5,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(label, style: AppText.body),
        ),
      ),
    ),
  );
}

final class _Pill extends StatelessWidget {
  const _Pill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: CupertinoColors.systemGreen.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(label, style: AppText.footnote),
    ),
  );
}
