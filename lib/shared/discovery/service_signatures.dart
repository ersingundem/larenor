import 'package:http/http.dart' as http;

import 'lan_scanner.dart';

/// Known default ports + a body-content probe for every integration that
/// has no real discovery protocol of its own — each app's web UI serves
/// an HTML page with its own name in the title, which is enough to
/// recognize it without needing any credentials up front.
class ServiceSignatures {
  static final jellyseerr = LanServiceSignature.bodyContains(
    'jellyseerr',
    ports: const [5055],
  );

  static final sonarr = LanServiceSignature.bodyContains(
    'sonarr',
    ports: const [8989],
  );

  static final radarr = LanServiceSignature.bodyContains(
    'radarr',
    ports: const [7878],
  );

  static final lidarr = LanServiceSignature.bodyContains(
    'lidarr',
    ports: const [8686],
  );

  static final readarr = LanServiceSignature.bodyContains(
    'readarr',
    ports: const [8787],
  );

  static final bazarr = LanServiceSignature.bodyContains(
    'bazarr',
    ports: const [6767],
  );

  static final prowlarr = LanServiceSignature.bodyContains(
    'prowlarr',
    ports: const [9696],
  );

  static final qbittorrent = LanServiceSignature.bodyContains(
    'qbittorrent',
    ports: const [8080, 8090],
  );

  /// Proxmox's version endpoint is unauthenticated by design and doesn't
  /// need a body-content check on an HTML title — this checks the JSON
  /// shape directly, over HTTPS with its default self-signed cert allowed
  /// (same trust relaxation as `buildProxmoxHttpClient`).
  static final proxmox = LanServiceSignature(
    ports: const [8006],
    path: '/api2/json/version',
    useHttps: true,
    allowSelfSignedCert: true,
    matches: (http.Response response) =>
        response.statusCode == 200 &&
        response.body.contains('"version"') &&
        response.body.contains('"data"'),
  );
}
