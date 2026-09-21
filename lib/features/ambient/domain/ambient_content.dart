import 'package:flutter/foundation.dart';

import '../../web_panel/domain/web_panel_policy.dart';

enum AmbientContentKind { video, pdf, web }

@immutable
final class AmbientContent {
  const AmbientContent._({
    required this.id,
    required this.kind,
    required this.sizeBytes,
    required this.webUrl,
  });

  factory AmbientContent.local({
    required String id,
    required AmbientContentKind kind,
    required int sizeBytes,
  }) {
    if (kind == AmbientContentKind.web) throw const AmbientContentException();
    return AmbientContent._(
      id: id,
      kind: kind,
      sizeBytes: sizeBytes,
      webUrl: null,
    ).._validate();
  }

  factory AmbientContent.web({required String id, required String url}) =>
      AmbientContent._(
        id: id,
        kind: AmbientContentKind.web,
        sizeBytes: 0,
        webUrl: url,
      ).._validate();

  factory AmbientContent.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw.length != 4 ||
        raw['id'] is! String ||
        raw['kind'] is! String ||
        raw['sizeBytes'] is! int ||
        !(raw.containsKey('webUrl') &&
            (raw['webUrl'] == null || raw['webUrl'] is String))) {
      throw const AmbientContentException();
    }
    final kind = AmbientContentKind.values
        .where((value) => value.name == raw['kind'])
        .firstOrNull;
    if (kind == null) throw const AmbientContentException();
    return AmbientContent._(
      id: raw['id'],
      kind: kind,
      sizeBytes: raw['sizeBytes'],
      webUrl: raw['webUrl'],
    ).._validate();
  }

  static final _id = RegExp(r'^[a-f0-9]{64}$');
  final String id;
  final AmbientContentKind kind;
  final int sizeBytes;
  final String? webUrl;

  WebPanelPolicy? get policy =>
      kind == AmbientContentKind.web ? WebPanelPolicy.fromUrl(webUrl!) : null;

  String get extension => switch (kind) {
    AmbientContentKind.video => 'mp4',
    AmbientContentKind.pdf => 'pdf',
    AmbientContentKind.web => throw const AmbientContentException(),
  };

  void _validate() {
    if (!_id.hasMatch(id) || sizeBytes < 0) {
      throw const AmbientContentException();
    }
    if (kind == AmbientContentKind.web) {
      final url = webUrl;
      final uri = url == null ? null : Uri.tryParse(url);
      if (sizeBytes != 0 ||
          url == null ||
          url.length > 2048 ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          policy == null) {
        throw const AmbientContentException();
      }
    } else if (webUrl != null || sizeBytes < 1) {
      throw const AmbientContentException();
    }
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'sizeBytes': sizeBytes,
    'webUrl': webUrl,
  };

  @override
  bool operator ==(Object other) =>
      other is AmbientContent &&
      other.id == id &&
      other.kind == kind &&
      other.sizeBytes == sizeBytes &&
      other.webUrl == webUrl;

  @override
  int get hashCode => Object.hash(id, kind, sizeBytes, webUrl);
}

class AmbientContentException implements Exception {
  const AmbientContentException({this.limit = false});
  final bool limit;

  @override
  String toString() => 'Ambient content unavailable';
}
