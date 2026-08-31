/// A view-model combining an `automation.*` entity's live state with its
/// entity-registry `unique_id` (== the id the `/api/config/automation/config`
/// editor endpoint expects), computed client-side — HA doesn't expose a
/// single "list all automations" endpoint.
class AutomationSummary {
  const AutomationSummary({
    required this.entityId,
    required this.friendlyName,
    required this.isOn,
    required this.automationId,
  });

  final String entityId;
  final String friendlyName;
  final bool isOn;

  /// Null when the registry lookup didn't return a `unique_id` — the
  /// automation can still be toggled via services, just not opened in the
  /// JSON editor (its config lives in an unknown location, e.g. a custom
  /// integration that didn't register one).
  final String? automationId;
}
