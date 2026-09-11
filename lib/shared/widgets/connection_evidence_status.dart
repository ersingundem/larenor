import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../../features/health/data/connection_evidence.dart';
import '../../features/health/data/integration_health.dart';
import '../../features/health/presentation/health_labels.dart';
import '../../l10n/generated/app_localizations.dart';
import '../theme/typography.dart';

List<String> connectionEvidenceLabels(
  AppLocalizations l10n,
  ConnectionEvidence evidence, {
  bool showTimestamp = true,
}) {
  final labels = <String>[healthStatusLabel(l10n, evidence.status)];
  if (evidence.status == HealthStatus.configured) {
    labels.add(l10n.healthNotVerified);
  }
  if (showTimestamp && evidence.lastVerifiedAt != null) {
    final verifiedAt = evidence.lastVerifiedAt!;
    labels.add(
      l10n.healthLastSuccessfulRead(
        DateFormat.yMd(l10n.localeName).add_Hm().format(verifiedAt.toLocal()),
      ),
    );
  }
  return labels;
}

/// Passive, secret-free visual evidence. It never starts a client or retries.
class ConnectionEvidenceStatus extends StatelessWidget {
  const ConnectionEvidenceStatus({
    super.key,
    required this.evidence,
    this.compact = false,
    this.showTimestamp = true,
  });

  final ConnectionEvidence evidence;
  final bool compact;
  final bool showTimestamp;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final labels = connectionEvidenceLabels(
      l10n,
      evidence,
      showTimestamp: showTimestamp,
    );
    final status = evidence.status;
    final color = switch (status) {
      HealthStatus.healthy => CupertinoColors.systemGreen,
      HealthStatus.offline ||
      HealthStatus.authenticationRequired ||
      HealthStatus.permissionDenied ||
      HealthStatus.error => CupertinoColors.systemRed,
      HealthStatus.stale ||
      HealthStatus.retrying => CupertinoColors.systemOrange,
      HealthStatus.reachable => CupertinoColors.systemBlue,
      _ => CupertinoColors.secondaryLabel,
    };
    final icon = switch (status) {
      HealthStatus.healthy => CupertinoIcons.checkmark_circle_fill,
      HealthStatus.reachable => CupertinoIcons.antenna_radiowaves_left_right,
      HealthStatus.offline ||
      HealthStatus.authenticationRequired ||
      HealthStatus.permissionDenied ||
      HealthStatus.error => CupertinoIcons.exclamationmark_circle_fill,
      HealthStatus.stale => CupertinoIcons.clock_fill,
      HealthStatus.connecting ||
      HealthStatus.retrying => CupertinoIcons.arrow_2_circlepath,
      HealthStatus.configured => CupertinoIcons.tray_fill,
      HealthStatus.notConfigured => CupertinoIcons.minus_circle,
    };
    final resolved = color.resolveFrom(context);
    if (compact) {
      return Semantics(
        key: const ValueKey('connection-evidence-status'),
        container: true,
        liveRegion: true,
        label: labels.join('. '),
        child: ExcludeSemantics(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(icon, size: 15, color: resolved),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      labels.first,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.footnote.copyWith(
                        color: resolved,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    for (final label in labels.skip(1))
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption1.copyWith(
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Semantics(
      key: const ValueKey('connection-evidence-status'),
      container: true,
      liveRegion: true,
      label: labels.join('. '),
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: resolved.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(icon, size: 18, color: resolved),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        labels.first,
                        maxLines: null,
                        style: AppText.footnote.copyWith(
                          color: resolved,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      for (final label in labels.skip(1)) ...[
                        const SizedBox(height: 2),
                        Text(
                          label,
                          maxLines: null,
                          style: AppText.caption1.copyWith(
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
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
}
