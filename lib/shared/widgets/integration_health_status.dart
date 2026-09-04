import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../features/health/data/integration_health.dart';
import '../../features/health/providers/health_providers.dart';
import '../../features/health/presentation/health_labels.dart';
import '../../features/navigation/providers/service_connection_providers.dart';
import '../../features/settings/data/app_service.dart';
import '../../l10n/generated/app_localizations.dart';
import '../theme/typography.dart';

/// Presents observed health only. Building this widget never binds a session,
/// starts a client, probes an endpoint or repeats a failed request.
class IntegrationHealthStatus extends ConsumerWidget {
  const IntegrationHealthStatus({
    super.key,
    required this.id,
    required this.configured,
    this.compact = false,
  });

  final IntegrationId id;
  final bool configured;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    if (!configured) return Text(l10n.navigationUnconfigured);

    final health =
        ref.watch(integrationHealthProvider(id)).value ??
        ref.read(healthMonitorProvider).read(id);
    final observedStatus = ref.watch(integrationHealthStatusProvider(id));
    // A local credential read may precede creation of any instrumented client.
    final status = health.configured ? observedStatus : HealthStatus.configured;
    final label = healthStatusLabel(l10n, status);
    final color = switch (status) {
      HealthStatus.healthy => CupertinoColors.systemGreen,
      HealthStatus.offline ||
      HealthStatus.authenticationRequired ||
      HealthStatus.permissionDenied ||
      HealthStatus.error => CupertinoColors.systemRed,
      HealthStatus.stale ||
      HealthStatus.retrying => CupertinoColors.systemOrange,
      _ => CupertinoColors.secondaryLabel,
    };
    final icon = switch (status) {
      HealthStatus.healthy => CupertinoIcons.checkmark_circle_fill,
      HealthStatus.offline ||
      HealthStatus.authenticationRequired ||
      HealthStatus.permissionDenied ||
      HealthStatus.error => CupertinoIcons.exclamationmark_circle,
      HealthStatus.stale => CupertinoIcons.clock,
      HealthStatus.connecting ||
      HealthStatus.retrying => CupertinoIcons.arrow_2_circlepath,
      _ => CupertinoIcons.circle,
    };
    final lastRead = health.configured ? health.lastSuccessfulRead : null;
    final secondary = AppText.caption1.copyWith(
      color: CupertinoColors.secondaryLabel.resolveFrom(context),
    );

    return Column(
      key: ValueKey('health-status-${id.name}'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 6),
              child: Icon(
                icon,
                size: compact ? 13 : 16,
                color: color.resolveFrom(context),
              ),
            ),
            Flexible(child: Text(label, maxLines: compact ? 2 : null)),
          ],
        ),
        if (status == HealthStatus.configured)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(l10n.healthNotVerified, style: secondary),
          ),
        if (lastRead != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              l10n.healthLastSuccessfulRead(
                DateFormat.yMd(l10n.localeName)
                    .add_Hm()
                    .format(lastRead.toLocal()),
              ),
              style: secondary,
              maxLines: compact ? 2 : null,
            ),
          ),
      ],
    );
  }
}

/// Uses the saved connection as a presence check, never as an online signal.
class SavedServiceHealthStatus extends ConsumerWidget {
  const SavedServiceHealthStatus({
    super.key,
    required this.service,
    this.compact = true,
  });

  final AppService service;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(savedServiceConnectionProvider(service));
    final l10n = AppLocalizations.of(context);
    if (connection.isLoading) return Text(l10n.commonLoading);
    if (connection.hasError) return Text(l10n.commonError);
    return IntegrationHealthStatus(
      id: IntegrationId.values.byName(service.name),
      configured: connection.value == true,
      compact: compact,
    );
  }
}

class ServiceHealthBanner extends StatelessWidget {
  const ServiceHealthBanner({super.key, required this.service});

  final AppService service;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: SavedServiceHealthStatus(service: service, compact: false),
    ),
  );
}
