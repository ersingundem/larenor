import 'package:flutter/foundation.dart';

import '../../dashboard/domain/dashboard_website_url.dart';

/// Exact web origin. Paths, fragments and queries never grant authority.
@immutable
class WebOrigin {
  const WebOrigin._(this.scheme, this.host, this.port);
  final String scheme;
  final String host;
  final int port;

  static WebOrigin? parse(String url) {
    final rawAuthority = RegExp(
      r'^https?://([^/?#]*)',
      caseSensitive: false,
    ).firstMatch(url)?.group(1);
    if (rawAuthority == null || rawAuthority.contains('%')) return null;
    final valid = dashboardWebsiteUrl(url);
    if (valid == null) return null;
    final uri = Uri.parse(valid);
    // Reject encoded authorities rather than guessing how WebView decodes them.
    if (uri.authority.contains('%') || uri.host.contains('*')) return null;
    return WebOrigin._(uri.scheme, uri.host.toLowerCase(), uri.port);
  }

  /// User grants must name only a whole origin, never a path or OAuth query.
  static WebOrigin? parseExact(String url) {
    final origin = parse(url);
    if (origin == null) return null;
    final uri = Uri.parse(url);
    if ((uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    return origin;
  }

  /// Contains no path, query, username or fragment.
  String get displayName => Uri(
    scheme: scheme,
    host: host,
    port: port == (scheme == 'https' ? 443 : 80) ? null : port,
  ).toString();

  @override
  bool operator ==(Object other) =>
      other is WebOrigin &&
      other.scheme == scheme &&
      other.host == host &&
      other.port == port;
  @override
  int get hashCode => Object.hash(scheme, host, port);
}

@immutable
class WebPanelPolicy {
  WebPanelPolicy._(this.initialUri, Set<WebOrigin> origins)
    : allowedOrigins = Set.unmodifiable(origins);
  final Uri initialUri;
  final Set<WebOrigin> allowedOrigins;

  static WebPanelPolicy? fromUrl(
    String url, {
    Set<WebOrigin> additionalOrigins = const {},
  }) {
    final origin = WebOrigin.parse(url);
    if (origin == null || additionalOrigins.length > 15) return null;
    return WebPanelPolicy._(Uri.parse(dashboardWebsiteUrl(url)!), {
      origin,
      ...additionalOrigins,
    });
  }

  bool allows(String url) {
    final origin = WebOrigin.parse(url);
    return origin != null && allowedOrigins.contains(origin);
  }

  @override
  bool operator ==(Object other) =>
      other is WebPanelPolicy &&
      other.initialUri == initialUri &&
      setEquals(other.allowedOrigins, allowedOrigins);
  @override
  int get hashCode =>
      Object.hash(initialUri, Object.hashAllUnordered(allowedOrigins));
}
