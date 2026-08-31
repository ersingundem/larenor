class ArrQualityProfile {
  const ArrQualityProfile({required this.id, required this.name});

  final int id;
  final String name;

  factory ArrQualityProfile.fromJson(Map<String, dynamic> json) =>
      ArrQualityProfile(
        id: json['id'] as int,
        name: json['name'] as String? ?? 'Profile ${json['id']}',
      );
}

class ArrRootFolder {
  const ArrRootFolder({required this.id, required this.path});

  final int id;
  final String path;

  factory ArrRootFolder.fromJson(Map<String, dynamic> json) => ArrRootFolder(
    id: json['id'] as int,
    path: json['path'] as String? ?? '/',
  );
}

/// Lidarr/Readarr-only picker — Sonarr/Radarr don't have metadata
/// profiles.
class ArrMetadataProfile {
  const ArrMetadataProfile({required this.id, required this.name});

  final int id;
  final String name;

  factory ArrMetadataProfile.fromJson(Map<String, dynamic> json) =>
      ArrMetadataProfile(
        id: json['id'] as int,
        name: json['name'] as String? ?? 'Profile ${json['id']}',
      );
}
