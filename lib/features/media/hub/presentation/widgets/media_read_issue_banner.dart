import 'package:flutter/cupertino.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../../../../shared/theme/typography.dart';
import '../../../../health/data/integration_health.dart';
import '../../../../health/presentation/health_labels.dart';
import '../../domain/media_read_result.dart';

/// Never displays raw exceptions, server addresses or credentials.
class MediaReadIssueBanner extends StatelessWidget {
  const MediaReadIssueBanner({
    super.key,
    required this.issues,
    required this.hasContent,
    this.onRetry,
  });
  final List<MediaReadIssue> issues;
  final bool hasContent;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final failures = <IntegrationId, Set<HealthFailure>>{};
    for (final issue in issues) {
      failures.putIfAbsent(issue.read.service, () => {}).add(issue.failure);
    }
    return Semantics(
      container: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: CupertinoColors.systemOrange
              .resolveFrom(context)
              .withValues(alpha: .12),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              hasContent
                  ? l10n.mediaReadPartialTitle
                  : l10n.mediaReadFailedTitle,
              style: AppText.headline,
            ),
            const SizedBox(height: 8),
            Text(
              hasContent
                  ? l10n.mediaReadPartialMessage
                  : l10n.mediaReadFailedMessage,
              style: AppText.subhead,
            ),
            const SizedBox(height: 10),
            for (final entry in failures.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${_serviceName(entry.key)} · ${entry.value.map((failure) => healthFailureLabel(l10n, failure)).toSet().join(', ')}',
                  style: AppText.footnote,
                ),
              ),
            if (onRetry != null)
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: onRetry,
                child: Text(l10n.commonRetry),
              ),
          ],
        ),
      ),
    );
  }
}

String _serviceName(IntegrationId service) => switch (service) {
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
