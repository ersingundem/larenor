import 'dart:convert';

import '../../../../shared/network/server_bound_client.dart';

/// Remembered choices only. Every run still requires an explicit preview and
/// confirmation, including after a portable backup restore.
class MovieNightPreset {
  const MovieNightPreset({
    required this.serverUrl,
    required this.startEntityId,
    this.finishEntityId,
  });
  static const storageKey = 'movie_night_v1';
  final String serverUrl;
  final String startEntityId;
  final String? finishEntityId;

  static bool validEntity(Object? value) =>
      value is String &&
      value.length <= 256 &&
      RegExp(r'^(scene|script)\.[a-z0-9_]+$').hasMatch(value);

  Map<String, dynamic> toJson() => {
    'version': 1,
    'serverUrl': serverUrl,
    'startEntityId': startEntityId,
    if (finishEntityId != null) 'finishEntityId': finishEntityId,
  };

  factory MovieNightPreset.decodeStored(Object value) {
    const invalid = FormatException('Invalid movie night settings');
    if (value is! String || utf8.encode(value).length > 16384) throw invalid;
    final json = jsonDecode(value);
    if (json is! Map<String, dynamic> ||
        json['version'] != 1 ||
        !const {
          'version',
          'serverUrl',
          'startEntityId',
          'finishEntityId',
        }.containsAll(json.keys) ||
        json['serverUrl'] is! String ||
        !validEntity(json['startEntityId']) ||
        (json['finishEntityId'] != null &&
            !validEntity(json['finishEntityId']))) {
      throw invalid;
    }
    return MovieNightPreset(
      serverUrl: parseServerUrl(json['serverUrl'] as String).toString(),
      startEntityId: json['startEntityId'] as String,
      finishEntityId: json['finishEntityId'] as String?,
    );
  }

  String encodeStored() {
    final encoded = jsonEncode(toJson());
    MovieNightPreset.decodeStored(encoded);
    return encoded;
  }
}
