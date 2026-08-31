/// An indexer entry from Prowlarr's `/api/v1/indexer`. Keeps the full
/// [raw] JSON so a PUT to toggle `enable` can spread the rest of the
/// object back unchanged — same "round-trip the full object" pattern as
/// Sonarr/Radarr's add flow.
class ProwlarrIndexer {
  const ProwlarrIndexer({
    required this.id,
    required this.name,
    required this.enabled,
    required this.protocol,
    required this.priority,
    required this.raw,
  });

  final int id;
  final String name;
  final bool enabled;
  final String protocol;
  final int priority;
  final Map<String, dynamic> raw;

  factory ProwlarrIndexer.fromJson(Map<String, dynamic> json) =>
      ProwlarrIndexer(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? 'Unknown',
        enabled: json['enable'] as bool? ?? false,
        protocol: json['protocol'] as String? ?? 'unknown',
        priority: (json['priority'] as num?)?.toInt() ?? 0,
        raw: json,
      );
}
