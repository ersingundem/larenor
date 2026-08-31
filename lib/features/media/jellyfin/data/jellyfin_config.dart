class JellyfinConfig {
  const JellyfinConfig({
    required this.baseUrl,
    required this.userId,
    required this.accessToken,
    required this.deviceId,
  });

  final String baseUrl;
  final String userId;
  final String accessToken;
  final String deviceId;
}
