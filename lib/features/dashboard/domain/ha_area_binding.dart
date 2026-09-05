import '../../../shared/network/server_bound_client.dart';

/// Explicit LOCAL relationship; no token and no authority to modify HA.
class HaAreaBinding {
  HaAreaBinding({
    required this.serverUrl,
    required this.areaId,
    required this.sourceName,
    Iterable<String> importedEntityIds = const [],
    Iterable<String> excludedEntityIds = const [],
  }) : importedEntityIds = List.unmodifiable(importedEntityIds),
       excludedEntityIds = List.unmodifiable(excludedEntityIds);
  final String serverUrl;
  final String areaId;

  /// Last accepted HA name. A different local room name is a manual override.
  final String sourceName;

  /// Members owned by synchronization, not manually pinned members.
  final List<String> importedEntityIds;

  /// Explicitly removed members must not return at the next refresh.
  final List<String> excludedEntityIds;

  HaAreaBinding copyWith({
    String? sourceName,
    Iterable<String>? importedEntityIds,
    Iterable<String>? excludedEntityIds,
  }) => HaAreaBinding(
    serverUrl: serverUrl,
    areaId: areaId,
    sourceName: sourceName ?? this.sourceName,
    importedEntityIds: importedEntityIds ?? this.importedEntityIds,
    excludedEntityIds: excludedEntityIds ?? this.excludedEntityIds,
  );

  Map<String, dynamic> toJson() => {
    'serverUrl': serverUrl,
    'areaId': areaId,
    'sourceName': sourceName,
    'importedEntityIds': importedEntityIds,
    'excludedEntityIds': excludedEntityIds,
  };

  factory HaAreaBinding.fromJson(Map<String, dynamic> json) {
    validateHaAreaBindingJson(json);
    return HaAreaBinding(
      serverUrl: json['serverUrl'] as String,
      areaId: json['areaId'] as String,
      sourceName: json['sourceName'] as String,
      importedEntityIds: (json['importedEntityIds'] as List).cast<String>(),
      excludedEntityIds: (json['excludedEntityIds'] as List).cast<String>(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HaAreaBinding &&
      serverUrl == other.serverUrl &&
      areaId == other.areaId &&
      sourceName == other.sourceName &&
      _sameList(importedEntityIds, other.importedEntityIds) &&
      _sameList(excludedEntityIds, other.excludedEntityIds);
  @override
  int get hashCode => Object.hash(
    serverUrl,
    areaId,
    sourceName,
    Object.hashAll(importedEntityIds),
    Object.hashAll(excludedEntityIds),
  );
  @override
  String toString() => 'HaAreaBinding';
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String normalizedAreaServerUrl(String value) =>
    parseServerUrl(value).toString();

void validateHaAreaBindingJson(Object? value) {
  const invalid = FormatException('Invalid room area binding');
  const keys = {
    'serverUrl',
    'areaId',
    'sourceName',
    'importedEntityIds',
    'excludedEntityIds',
  };
  if (value is! Map<String, dynamic> ||
      value.keys.toSet().difference(keys).isNotEmpty ||
      !value.keys.toSet().containsAll(keys)) {
    throw invalid;
  }
  for (final key in ['serverUrl', 'areaId', 'sourceName']) {
    final text = value[key];
    if (text is! String ||
        text.isEmpty ||
        text.length > (key == 'serverUrl' ? 2048 : 256) ||
        text.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw invalid;
    }
  }
  try {
    if (normalizedAreaServerUrl(value['serverUrl'] as String) !=
        value['serverUrl']) {
      throw invalid;
    }
  } catch (_) {
    throw invalid;
  }
  final imported = _ids(value['importedEntityIds']);
  final excluded = _ids(value['excludedEntityIds']);
  if (imported.intersection(excluded).isNotEmpty) throw invalid;
}

Set<String> _ids(Object? value) {
  const invalid = FormatException('Invalid room area binding');
  if (value is! List || value.length > 10000) throw invalid;
  final ids = <String>{};
  for (final id in value) {
    if (id is! String ||
        id.length > 256 ||
        !RegExp(r'^[a-z0-9_]+\.[a-z0-9_]+$').hasMatch(id) ||
        !ids.add(id)) {
      throw invalid;
    }
  }
  return ids;
}
