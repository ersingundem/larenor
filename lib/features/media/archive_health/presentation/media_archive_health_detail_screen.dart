import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../domain/media_archive_health.dart';
import 'media_archive_savings_candidate_screen.dart';

final class MediaArchiveHealthDetailScreen extends StatelessWidget {
  const MediaArchiveHealthDetailScreen({super.key, required this.snapshot});
  final MediaArchiveHealthSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AppPageScaffold(
      child: CustomScrollView(
        key: const PageStorageKey('media-archive-details-scroll'),
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l.mediaArchiveDetailsTitle),
            leading: CupertinoButton(
              key: const ValueKey('media-archive-details-back'),
              minimumSize: const Size(48, 48),
              padding: EdgeInsets.zero,
              onPressed: Navigator.of(context).canPop()
                  ? () => Navigator.of(context).maybePop()
                  : null,
              child: const Icon(CupertinoIcons.back),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            sliver: SliverList.list(
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _state(l, snapshot.state),
                    style: AppText.headline,
                  ),
                ),
                const SizedBox(height: 6),
                Text(l.mediaArchiveDetailReadOnly, style: AppText.footnote),
                const SizedBox(height: 8),
                Text(
                  l.mediaArchiveCapturedAt(
                    snapshot.generatedAt.toLocal().toString(),
                  ),
                  style: AppText.footnote,
                ),
                const SizedBox(height: 20),
                Semantics(
                  header: true,
                  child: Text(
                    l.mediaArchiveSourcesTitle,
                    style: AppText.headline,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final entry in snapshot.sourceStates.entries)
                      _SourceChip(
                        source: _sourceName(entry.key),
                        state: _sourceState(l, entry.value),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                Semantics(
                  header: true,
                  child: Text(
                    l.mediaArchiveIssuesTitle,
                    style: AppText.headline,
                  ),
                ),
                const SizedBox(height: 10),
                if (snapshot.issues.isEmpty)
                  Text(l.mediaArchiveIssuesEmpty)
                else
                  _ResponsiveCards(
                    children: [
                      for (final issue in snapshot.issues)
                        _EvidenceCard(
                          semanticsLabel:
                              '${issue.title}, ${_severity(l, issue.severity)}, ${_issue(l, issue.code)}',
                          title: issue.title,
                          subtitle:
                              '${_sourceName(issue.source)} · ${_severity(l, issue.severity)}',
                          details: [
                            _issue(l, issue.code),
                            if (issue.observedBytes > 0)
                              l.mediaArchiveObservedSize(
                                _bytes(issue.observedBytes),
                              ),
                          ],
                          icon:
                              issue.severity ==
                                  MediaArchiveIssueSeverity.critical
                              ? CupertinoIcons.exclamationmark_triangle_fill
                              : CupertinoIcons.exclamationmark_circle,
                        ),
                    ],
                  ),
                const SizedBox(height: 24),
                Semantics(
                  header: true,
                  child: Text(
                    l.mediaArchiveSavingsTitle,
                    style: AppText.headline,
                  ),
                ),
                const SizedBox(height: 6),
                Text(l.mediaArchiveSavingsHint, style: AppText.footnote),
                const SizedBox(height: 10),
                Text(
                  snapshot.savingsPlan.ready
                      ? l.mediaArchivePlanReady
                      : l.mediaArchivePlanPartial,
                  style: AppText.body,
                ),
                const SizedBox(height: 4),
                Text(
                  l.mediaArchivePlanTotal(
                    _bytes(snapshot.savingsPlan.totalPotentialBytes),
                  ),
                  style: AppText.footnote,
                ),
                if (snapshot.savingsPlan.truncated) ...[
                  const SizedBox(height: 4),
                  Text(l.mediaArchivePlanTruncated, style: AppText.footnote),
                ],
                if (snapshot.savingsPlan.dataGaps.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Semantics(
                    header: true,
                    child: Text(
                      l.mediaArchiveDataGapsTitle,
                      style: AppText.headline,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final gap in snapshot.savingsPlan.dataGaps)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        l.mediaArchiveDataGap(
                          _kind(l, gap.lane),
                          _gapReason(l, gap.reason),
                        ),
                        style: AppText.footnote,
                      ),
                    ),
                ],
                for (final kind in MediaArchiveSavingKind.values) ...[
                  const SizedBox(height: 18),
                  Semantics(
                    header: true,
                    child: Text(_kind(l, kind), style: AppText.headline),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _lane(l, snapshot.savingsPlan.laneStates[kind]!),
                    style: AppText.footnote,
                  ),
                  const SizedBox(height: 8),
                  if (snapshot.savingsPlan.candidates
                      .where((candidate) => candidate.kind == kind)
                      .isEmpty)
                    Text(l.mediaArchiveSavingsEmpty)
                  else
                    _ResponsiveCards(
                      children: [
                        for (
                          var index = 0;
                          index < snapshot.savingsPlan.candidates.length;
                          index++
                        )
                          if (snapshot.savingsPlan.candidates[index].kind ==
                              kind)
                            _SavingsCandidateButton(
                              key: ValueKey(
                                'media-archive-saving-${kind.name}-$index',
                              ),
                              candidate: snapshot.savingsPlan.candidates[index],
                              plan: snapshot.savingsPlan,
                              kindLabel: _kind(l, kind),
                              potentialLabel: l.mediaArchivePotentialValue(
                                _bytes(
                                  snapshot
                                      .savingsPlan
                                      .candidates[index]
                                      .potentialBytes,
                                ),
                              ),
                              evidenceLabels: snapshot
                                  .savingsPlan
                                  .candidates[index]
                                  .evidence
                                  .map((value) => _evidence(l, value))
                                  .toList(),
                              icon: _kindIcon(kind),
                            ),
                      ],
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _state(AppLocalizations l, MediaArchiveSnapshotState state) =>
      switch (state) {
        MediaArchiveSnapshotState.healthy => l.mediaArchiveHealthyEvidence,
        MediaArchiveSnapshotState.attention => l.mediaArchiveAttentionEvidence,
        MediaArchiveSnapshotState.incomplete => l.mediaArchivePartialEvidence,
      };

  static String _severity(
    AppLocalizations l,
    MediaArchiveIssueSeverity severity,
  ) => switch (severity) {
    MediaArchiveIssueSeverity.warning => l.mediaArchiveSeverityWarning,
    MediaArchiveIssueSeverity.critical => l.mediaArchiveSeverityCritical,
  };

  static String _issue(AppLocalizations l, MediaArchiveIssueCode code) =>
      switch (code) {
        MediaArchiveIssueCode.missingMedia => l.mediaArchiveIssueMissingMedia,
        MediaArchiveIssueCode.missingFile => l.mediaArchiveIssueMissingFile,
        MediaArchiveIssueCode.corruptMedia => l.mediaArchiveIssueCorrupt,
        MediaArchiveIssueCode.unplayableMedia => l.mediaArchiveIssueUnplayable,
        MediaArchiveIssueCode.downloadError => l.mediaArchiveIssueDownload,
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

  static String _lane(AppLocalizations l, MediaArchiveSavingLaneState state) =>
      switch (state) {
        MediaArchiveSavingLaneState.verified => l.mediaArchivePlanLaneVerified,
        MediaArchiveSavingLaneState.partial => l.mediaArchivePlanLanePartial,
        MediaArchiveSavingLaneState.unsupported =>
          l.mediaArchivePlanLaneUnsupported,
        MediaArchiveSavingLaneState.unavailable =>
          l.mediaArchivePlanLaneUnavailable,
        MediaArchiveSavingLaneState.stale => l.mediaArchivePlanLaneStale,
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

  static IconData _kindIcon(MediaArchiveSavingKind kind) => switch (kind) {
    MediaArchiveSavingKind.duplicate => CupertinoIcons.square_on_square,
    MediaArchiveSavingKind.transcode => CupertinoIcons.arrow_2_circlepath,
    MediaArchiveSavingKind.retention => CupertinoIcons.archivebox,
  };

  static String _sourceState(
    AppLocalizations l,
    MediaArchiveSourceState state,
  ) => switch (state) {
    MediaArchiveSourceState.verified => l.mediaArchiveSourceVerified,
    MediaArchiveSourceState.unavailable => l.mediaArchiveSourceUnavailable,
    MediaArchiveSourceState.unsupported => l.mediaArchiveSourceUnsupported,
    MediaArchiveSourceState.stale => l.mediaArchiveSourceStale,
  };

  static String _sourceName(String source) =>
      '${source[0].toUpperCase()}${source.substring(1)}';

  static String _bytes(int value) {
    if (value >= 1000000000) {
      return '${(value / 1000000000).toStringAsFixed(1)} GB';
    }
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)} MB';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)} KB';
    return '$value B';
  }
}

final class _SavingsCandidateButton extends StatelessWidget {
  const _SavingsCandidateButton({
    super.key,
    required this.candidate,
    required this.plan,
    required this.kindLabel,
    required this.potentialLabel,
    required this.evidenceLabels,
    required this.icon,
  });

  final MediaArchiveSavingsCandidate candidate;
  final MediaArchiveSavingsPlan plan;
  final String kindLabel, potentialLabel;
  final List<String> evidenceLabels;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Semantics(
      button: true,
      label:
          '${candidate.title}, $potentialLabel, $kindLabel, ${l.mediaArchiveComparisonOpen}',
      child: ExcludeSemantics(
        child: CupertinoButton(
          minimumSize: const Size(48, 48),
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).push(
            CupertinoPageRoute<void>(
              builder: (_) => MediaArchiveSavingsCandidateScreen(
                candidate: candidate,
                dataGaps: plan.dataGaps,
              ),
            ),
          ),
          child: _EvidenceCard(
            semanticsLabel: candidate.title,
            title: candidate.title,
            subtitle: potentialLabel,
            details: evidenceLabels,
            icon: icon,
          ),
        ),
      ),
    );
  }
}

final class _ResponsiveCards extends StatelessWidget {
  const _ResponsiveCards({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 900 ? 2 : 1;
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

final class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.source, required this.state});
  final String source, state;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '$source, $state',
    child: ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text('$source · $state'),
        ),
      ),
    ),
  );
}

final class _EvidenceCard extends StatelessWidget {
  const _EvidenceCard({
    required this.semanticsLabel,
    required this.title,
    required this.subtitle,
    required this.details,
    required this.icon,
  });
  final String semanticsLabel, title, subtitle;
  final List<String> details;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: semanticsLabel,
    child: ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
            context,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: CupertinoColors.separator.resolveFrom(context),
            width: 0.5,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppText.headline),
                    const SizedBox(height: 4),
                    Text(subtitle, style: AppText.body),
                    for (final detail in details) ...[
                      const SizedBox(height: 5),
                      Text('• $detail', style: AppText.footnote),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
