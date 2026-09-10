import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/health/data/connection_evidence.dart';
import '../../features/health/data/integration_health.dart';
import '../../features/health/providers/health_providers.dart';
import '../../features/navigation/providers/service_connection_providers.dart';
import '../../features/settings/data/app_service.dart';
import '../../l10n/generated/app_localizations.dart';
import 'connection_evidence_status.dart';

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
    if (!configured) {
      return ConnectionEvidenceStatus(
        evidence: const ConnectionEvidence.none(),
        compact: compact,
      );
    }

    final health =
        ref.watch(integrationHealthProvider(id)).value ??
        ref.read(healthMonitorProvider).read(id);
    final observedStatus = ref.watch(integrationHealthStatusProvider(id));
    // A local credential read may precede creation of any instrumented client.
    final status = health.configured ? observedStatus : HealthStatus.configured;
    return KeyedSubtree(
      key: ValueKey('health-status-${id.name}'),
      child: ConnectionEvidenceStatus(
        evidence: ConnectionEvidence.fromHealth(health, status),
        compact: compact,
      ),
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
