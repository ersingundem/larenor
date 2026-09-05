import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../../../../shared/theme/typography.dart';
import '../../../../health/data/integration_health.dart';
import '../../../../health/presentation/health_labels.dart';
import '../../../jellyseerr/presentation/jellyseerr_status_label.dart';
import '../../domain/media_title.dart';

String mediaAvailabilityLabel(AppLocalizations l10n, MediaAvailability value) =>
    switch (value) {
      MediaAvailability.inLibrary => l10n.mediaStatusInLibrary,
      MediaAvailability.downloading => l10n.mediaStatusDownloading,
      MediaAvailability.requested => l10n.mediaStatusRequested,
      MediaAvailability.monitored => l10n.mediaStatusMonitored,
      MediaAvailability.notAvailable => l10n.mediaStatusNotAvailable,
      MediaAvailability.queued => l10n.mediaStatusQueued,
      MediaAvailability.paused => l10n.mediaStatusPaused,
      MediaAvailability.importing => l10n.mediaStatusImporting,
      MediaAvailability.partiallyAvailable =>
        l10n.mediaStatusPartiallyAvailable,
      MediaAvailability.available => l10n.mediaStatusAvailable,
      MediaAvailability.failed => l10n.mediaStatusFailed,
      MediaAvailability.unknown => l10n.mediaStatusUnknown,
    };

IconData mediaAvailabilityIcon(MediaAvailability value) => switch (value) {
  MediaAvailability.inLibrary => CupertinoIcons.checkmark_circle_fill,
  MediaAvailability.downloading => CupertinoIcons.arrow_down_circle_fill,
  MediaAvailability.requested ||
  MediaAvailability.queued => CupertinoIcons.clock_fill,
  MediaAvailability.paused => CupertinoIcons.pause_circle_fill,
  MediaAvailability.importing => CupertinoIcons.folder_fill,
  MediaAvailability.partiallyAvailable => CupertinoIcons.circle_lefthalf_fill,
  MediaAvailability.available => CupertinoIcons.doc_fill,
  MediaAvailability.failed => CupertinoIcons.exclamationmark_triangle_fill,
  MediaAvailability.unknown => CupertinoIcons.question_circle_fill,
  MediaAvailability.monitored => CupertinoIcons.eye_fill,
  MediaAvailability.notAvailable => CupertinoIcons.cloud,
};

Color mediaAvailabilityColor(MediaAvailability value) => switch (value) {
  MediaAvailability.inLibrary => CupertinoColors.systemGreen,
  MediaAvailability.downloading ||
  MediaAvailability.importing => CupertinoColors.systemBlue,
  MediaAvailability.requested ||
  MediaAvailability.queued ||
  MediaAvailability.partiallyAvailable => CupertinoColors.systemOrange,
  MediaAvailability.failed => CupertinoColors.systemRed,
  MediaAvailability.monitored => CupertinoColors.systemPurple,
  _ => CupertinoColors.systemGrey,
};

String mediaServiceName(IntegrationId service) => switch (service) {
  IntegrationId.ha => 'Home Assistant',
  IntegrationId.jellyfin => 'Jellyfin',
  IntegrationId.jellyseerr => 'Jellyseerr',
  IntegrationId.sonarr => 'Sonarr',
  IntegrationId.radarr => 'Radarr',
  IntegrationId.lidarr => 'Lidarr',
  IntegrationId.readarr => 'Readarr',
  IntegrationId.bazarr => 'Bazarr',
  IntegrationId.prowlarr => 'Prowlarr',
  IntegrationId.qbittorrent => 'qBittorrent',
  IntegrationId.keenetic => 'Keenetic',
  IntegrationId.proxmox => 'Proxmox',
};

/// Independent source evidence: an existing playable episode does not conceal
/// a different episode's download, and an imported file is not playback proof.
class MediaProgressCard extends StatelessWidget {
  const MediaProgressCard({
    super.key,
    required this.title,
    this.onRefresh,
    this.onOpenService,
  });
  final MediaTitle title;
  final VoidCallback? onRefresh;
  final void Function(IntegrationId service)? onOpenService;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final sources = <IntegrationId>{
      if (title.jellyfinItemId != null || title.jellyfinSeriesId != null)
        IntegrationId.jellyfin,
      if (title.arrItemId != null)
        title.isTv ? IntegrationId.sonarr : IntegrationId.radarr,
      if (title.requestStatus != null || title.jellyseerrMediaId != null)
        IntegrationId.jellyseerr,
      ...title.transfers.map((item) => item.source),
      ...title.readIssues.map((issue) => issue.read.service),
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                mediaAvailabilityIcon(title.availability),
                color: CupertinoDynamicColor.resolve(
                  mediaAvailabilityColor(title.availability),
                  context,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  mediaAvailabilityLabel(l10n, title.availability),
                  style: AppText.headline,
                ),
              ),
            ],
          ),
          if (title.isStale)
            Text(l10n.mediaProgressStale, style: AppText.footnote),
          if (title.readAt != null)
            Text(
              l10n.mediaProgressUpdated(
                DateFormat.yMd(l10n.localeName)
                    .add_Hm()
                    .format(title.readAt!.toLocal()),
              ),
              style: AppText.caption1,
            ),
          if (title.requestStatus != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Jellyseerr · ${jellyseerrRequestStatusLabel(context, title.requestStatus!)}',
                style: AppText.subhead,
              ),
            ),
          if (title.monitored == true)
            Text(l10n.mediaStatusMonitoredLabel, style: AppText.footnote),
          for (final transfer in title.transfers.take(10)) ...[
            const SizedBox(height: 12),
            Text(
              '${mediaServiceName(transfer.source)} · ${mediaAvailabilityLabel(l10n, transfer.stage)}',
              style: AppText.subhead,
            ),
            if (transfer.seasonNumber != null)
              Text(
                l10n.mediaSeasonLabel(transfer.seasonNumber!),
                style: AppText.footnote,
              ),
            if (transfer.progress != null && transfer.progress!.isFinite)
              Text(
                '${(transfer.progress!.clamp(0, 1) * 100).round()}%',
                style: AppText.footnote,
              )
            else if (transfer.stage == MediaAvailability.downloading ||
                transfer.stage == MediaAvailability.queued)
              Text(l10n.mediaProgressUnknown, style: AppText.footnote),
          ],
          for (final issue in title.readIssues)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${mediaServiceName(issue.read.service)} · ${healthFailureLabel(l10n, issue.failure)}',
                style: AppText.footnote,
              ),
            ),
          if (sources.isNotEmpty)
            Wrap(
              spacing: 12,
              children: [
                for (final source in sources.where(
                  (source) => source != IntegrationId.ha,
                ))
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    key: ValueKey('media-open-${source.name}'),
                    onPressed: () => onOpenService != null
                        ? onOpenService!(source)
                        : context.push('/system/${source.name}'),
                    child: Text(
                      l10n.mediaOpenService(mediaServiceName(source)),
                    ),
                  ),
              ],
            ),
          if (onRefresh != null)
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: onRefresh,
              child: Text(l10n.commonRefresh),
            ),
        ],
      ),
    );
  }
}
