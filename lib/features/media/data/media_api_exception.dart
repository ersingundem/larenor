/// Shared exception type across every media-service client (Jellyfin,
/// Jellyseerr, Sonarr, Radarr) — mirrors `HaApiException`'s role for the
/// Home Assistant client, kept separate since these are unrelated services.
class MediaApiException implements Exception {
  MediaApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'MediaApiException: $message';
}
