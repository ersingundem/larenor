import 'package:flutter/foundation.dart';

import 'web_panel_policy.dart';

/// Portable presentation preferences only. No website cookies or credentials.
@immutable
class WebPanelOptions {
  WebPanelOptions({
    List<String> additionalOrigins = const [],
    this.zoomEnabled = true,
    this.textZoom = 100,
  }) : additionalOrigins = List.unmodifiable(additionalOrigins) {
    validateJson(toJson());
  }

  final List<String> additionalOrigins;
  final bool zoomEnabled;
  final int textZoom;

  factory WebPanelOptions.fromJson(Map<String, dynamic> json) {
    validateJson(json);
    return WebPanelOptions(
      additionalOrigins: (json['additionalOrigins'] as List? ?? const [])
          .cast<String>(),
      zoomEnabled: json['zoomEnabled'] as bool? ?? true,
      textZoom: json['textZoom'] as int? ?? 100,
    );
  }

  Map<String, dynamic> toJson() => {
    'additionalOrigins': additionalOrigins,
    'zoomEnabled': zoomEnabled,
    'textZoom': textZoom,
  };

  static void validateJson(Object? value) {
    const invalid = FormatException('Invalid web panel options');
    if (value is! Map<String, dynamic> ||
        !const {
          'additionalOrigins',
          'zoomEnabled',
          'textZoom',
        }.containsAll(value.keys)) {
      throw invalid;
    }
    final origins = value.containsKey('additionalOrigins')
        ? value['additionalOrigins']
        : const [];
    if (origins is! List || origins.length > 15) throw invalid;
    final unique = <String>{};
    for (final raw in origins) {
      if (raw is! String || raw.length > 4096) throw invalid;
      final origin = WebOrigin.parseExact(raw);
      if (origin == null || origin.displayName != raw || !unique.add(raw)) {
        throw invalid;
      }
    }
    if (value.containsKey('zoomEnabled') && value['zoomEnabled'] is! bool) {
      throw invalid;
    }
    final zoom = value.containsKey('textZoom') ? value['textZoom'] : 100;
    if (zoom is! int || zoom < 75 || zoom > 200) throw invalid;
  }

  WebPanelPolicy? policyFor(String url) => WebPanelPolicy.fromUrl(
    url,
    additionalOrigins: {
      for (final origin in additionalOrigins) WebOrigin.parseExact(origin)!,
    },
  );

  @override
  bool operator ==(Object other) =>
      other is WebPanelOptions &&
      listEquals(additionalOrigins, other.additionalOrigins) &&
      zoomEnabled == other.zoomEnabled &&
      textZoom == other.textZoom;
  @override
  int get hashCode =>
      Object.hash(Object.hashAll(additionalOrigins), zoomEnabled, textZoom);
}

/// Shared dashboard/backup boundary. Other tile kinds cannot carry web grants.
bool hasValidWebPanelTileFields(Map<String, dynamic> tile) {
  final raw = tile['webPanel'];
  if (raw == null) return true;
  if (tile['type'] != 'webview') return false;
  try {
    WebPanelOptions.validateJson(raw);
    final url = tile['url'];
    return url is String && WebOrigin.parse(url) != null;
  } catch (_) {
    return false;
  }
}
