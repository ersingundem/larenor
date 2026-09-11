import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dashboard_tile_button.dart';

import '../../../../features/health/data/connection_evidence.dart';
import '../../../../features/health/data/integration_health.dart';
import '../../../../features/health/providers/health_providers.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/connection_evidence_status.dart';
import '../../../navigation/providers/service_connection_providers.dart';
import '../../../settings/data/app_service.dart';
import '../../../../shared/widgets/brand_icon.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/icon_sizes.dart';

/// Shared visual shell for the 11 external-service summary tiles — same
/// icon/title header, a "not connected" placeholder when the service
/// isn't configured, and up to a few compact content lines otherwise.
/// Unlike the HA-entity tiles these aren't per-entity, they're per-service
/// (one tile references the app-wide service connection directly), so
/// there's no entity lookup here — just a tap-through to that service's
/// own screen.
class ServiceTileShell extends StatelessWidget {
  const ServiceTileShell({
    super.key,
    required this.icon,
    required this.title,
    required this.connected,
    required this.onTap,
    required this.lines,
    this.service,
    this.evidence,
  });

  final IconData icon;
  final String title;
  final bool connected;
  final VoidCallback? onTap;
  final List<String> lines;

  /// When set and a real vendored logo exists for it, that logo is shown
  /// via [BrandIcon] in the header instead of the generic [icon].
  final AppService? service;
  final ConnectionEvidence? evidence;

  @override
  Widget build(BuildContext context) {
    final service = this.service;
    if (evidence == null && service != null) {
      return _ObservedServiceTileShell(shell: this, service: service);
    }
    return _build(context, configured: connected, evidence: evidence);
  }

  Widget _build(
    BuildContext context, {
    required bool configured,
    ConnectionEvidence? evidence,
    String? transientStatus,
  }) {
    final service = this.service;
    final l10n = AppLocalizations.of(context);
    final statusLabels = evidence == null
        ? transientStatus == null
              ? const <String>[]
              : <String>[transientStatus]
        : connectionEvidenceLabels(l10n, evidence, showTimestamp: false);
    final contentLines = configured ? lines : const Iterable<String>.empty();
    return DashboardTileButton(
      label: [
        title,
        ...statusLabels,
        ...contentLines,
        if (!configured && statusLabels.isEmpty) l10n.navigationUnconfigured,
      ].join(', '),
      onPressed: onTap,
      child: ColoredBox(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        child: Padding(
          padding: Insets.tile,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (service != null && hasBrandIcon(service))
                    BrandIcon(service: service, size: IconSizes.body)
                  else
                    Icon(
                      icon,
                      size: 18,
                      color: CupertinoTheme.of(context).primaryColor,
                    ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.tileTitle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gap.sm),
              if (evidence != null)
                ConnectionEvidenceStatus(
                  evidence: evidence,
                  compact: true,
                  showTimestamp: false,
                )
              else if (transientStatus != null)
                Text(
                  transientStatus,
                  style: TextStyle(
                    fontSize: AppText.tileSubtitle.fontSize,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                )
              else if (!configured)
                Text(
                  l10n.commonNotConnected,
                  style: TextStyle(
                    fontSize: AppText.tileSubtitle.fontSize,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                )
              else
                for (final line in contentLines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppText.tileSubtitle.fontSize,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                  ),
              if ((evidence != null || transientStatus != null) &&
                  contentLines.isNotEmpty)
                const SizedBox(height: 4),
              if (evidence != null || transientStatus != null)
                for (final line in contentLines)
                  Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppText.tileSubtitle.fontSize,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ObservedServiceTileShell extends ConsumerWidget {
  const _ObservedServiceTileShell({required this.shell, required this.service});

  final ServiceTileShell shell;
  final AppService service;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(savedServiceConnectionProvider(service));
    final l10n = AppLocalizations.of(context);
    if (connection.isLoading) {
      return shell._build(
        context,
        configured: false,
        transientStatus: l10n.commonLoading,
      );
    }
    if (connection.hasError) {
      return shell._build(
        context,
        configured: false,
        transientStatus: l10n.commonError,
      );
    }
    final configured = connection.value == true;
    if (!configured) {
      return shell._build(
        context,
        configured: false,
        evidence: const ConnectionEvidence.none(),
      );
    }
    final id = IntegrationId.values.byName(service.name);
    final health =
        ref.watch(integrationHealthProvider(id)).value ??
        ref.read(healthMonitorProvider).read(id);
    final observed = ref.watch(integrationHealthStatusProvider(id));
    return shell._build(
      context,
      configured: true,
      evidence: ConnectionEvidence.fromHealth(
        health,
        health.configured ? observed : HealthStatus.configured,
      ),
    );
  }
}
