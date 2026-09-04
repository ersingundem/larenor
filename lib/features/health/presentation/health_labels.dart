import '../../../l10n/generated/app_localizations.dart';
import '../data/integration_health.dart';

String healthFailureLabel(
  AppLocalizations l10n,
  HealthFailure failure,
) => switch (failure) {
  HealthFailure.authentication => l10n.healthAuthenticationRequired,
  HealthFailure.permission => l10n.healthPermissionDenied,
  HealthFailure.transport || HealthFailure.timeout => l10n.healthUnavailable,
  HealthFailure.server || HealthFailure.invalidResponse => l10n.healthReadError,
};

String healthStatusLabel(AppLocalizations l10n, HealthStatus status) =>
    switch (status) {
      HealthStatus.notConfigured => l10n.navigationUnconfigured,
      HealthStatus.configured => l10n.navigationSavedConnection,
      HealthStatus.connecting => l10n.healthConnecting,
      HealthStatus.reachable => l10n.healthReachable,
      HealthStatus.healthy => l10n.healthReadCurrent,
      HealthStatus.stale => l10n.healthReadStale,
      HealthStatus.retrying => l10n.healthRetrying,
      HealthStatus.offline => healthFailureLabel(l10n, HealthFailure.transport),
      HealthStatus.authenticationRequired => healthFailureLabel(
        l10n,
        HealthFailure.authentication,
      ),
      HealthStatus.permissionDenied => healthFailureLabel(
        l10n,
        HealthFailure.permission,
      ),
      HealthStatus.error => healthFailureLabel(
        l10n,
        HealthFailure.invalidResponse,
      ),
    };
