import 'ha_media_inventory.dart';

enum HaPlaybackFailure {
  authentication,
  permission,
  transport,
  timeout,
  invalidResponse,
  unavailable,
  unsupportedSource,
  unsupportedTarget,
  sourceChanged,
  invalidIntent,
  expiredIntent,
  busy,
}

enum HaPlaybackReceiptStatus { accepted, observed, unconfirmed }

class HaPlaybackException implements Exception {
  const HaPlaybackException(this.failure, {this.outcomeUnknown = false});
  final HaPlaybackFailure failure;
  final bool outcomeUnknown;
  @override
  String toString() => 'Home Assistant playback could not be completed';
}

/// A source identity from HA's media-source browser, never a resolved media URL.
/// Artwork and arbitrary metadata are intentionally not retained or forwarded.
class HaMediaNode {
  const HaMediaNode({
    required this.id,
    required this.title,
    required this.mediaType,
    required this.mediaClass,
    required this.canPlay,
    required this.canExpand,
  });
  final String id, title, mediaType, mediaClass;
  final bool canPlay, canExpand;
  bool get isAudio => mediaType.startsWith('audio/');
  bool get isVideo => mediaType.startsWith('video/');
  bool get playable => canPlay && !canExpand && (isAudio || isVideo);
  bool sameSource(HaMediaNode other) =>
      id == other.id &&
      title == other.title &&
      mediaType == other.mediaType &&
      mediaClass == other.mediaClass &&
      canPlay == other.canPlay &&
      canExpand == other.canExpand;
}

class HaMediaBrowsePage {
  HaMediaBrowsePage({
    required this.parent,
    required List<HaMediaNode> children,
    required this.readAt,
    this.notShown = 0,
  }) : children = List.unmodifiable(children);
  final HaMediaNode parent;
  final List<HaMediaNode> children;
  final DateTime readAt;
  final int notShown;
}

class HaPlaybackReceipt {
  const HaPlaybackReceipt({
    required this.status,
    required this.target,
    required this.source,
    required this.acceptedAt,
    this.observedAt,
  });
  final HaPlaybackReceiptStatus status;
  final HaMediaTarget target;
  final HaMediaNode source;
  final DateTime acceptedAt;
  final DateTime? observedAt;
}

class HaPlaybackSnapshot {
  const HaPlaybackSnapshot({
    this.configured = true,
    this.isLoading = false,
    this.isBusy = false,
    this.inventory,
    this.page,
    this.failure,
    this.receipt,
    this.outcomeUnknown = false,
  });
  final bool configured, isLoading, isBusy, outcomeUnknown;
  final HaMediaInventory? inventory;
  final HaMediaBrowsePage? page;
  final HaPlaybackFailure? failure;
  final HaPlaybackReceipt? receipt;
}

Never invalidHaMedia() =>
    throw const HaPlaybackException(HaPlaybackFailure.invalidResponse);

String? haMediaText(Object? value, {int limit = 512}) {
  if (value == null) return null;
  if (value is! String ||
      value.length > limit ||
      value.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
    invalidHaMedia();
  }
  return value.isEmpty ? null : value;
}

Map<String, dynamic> haMediaObject(Object? value, {int limit = 256}) {
  if (value is! Map ||
      value.length > limit ||
      value.keys.any((k) => k is! String)) {
    invalidHaMedia();
  }
  return Map<String, dynamic>.from(value);
}

String haMediaSourceId(String value, {bool allowRoot = true}) {
  if ((allowRoot && value == 'media-source://')) return value;
  if (value.length > 4096 ||
      !RegExp(r'^media-source://[a-z0-9](?:[a-z0-9_]*[a-z0-9])?(?:/[^/].*)?$')
          .hasMatch(value) ||
      value.contains(RegExp(r'[\x00-\x1F\x7F\\?#@]')) ||
      value.substring('media-source://'.length).contains(':') ||
      RegExp(
        r'%(?:0[0-9a-f]|1[0-9a-f]|7f|5c|3f|23|3a|40|25)',
        caseSensitive: false,
      ).hasMatch(value)) {
    throw const HaPlaybackException(HaPlaybackFailure.unsupportedSource);
  }
  return value;
}

HaMediaBrowsePage parseHaMediaBrowse(Object? raw, DateTime readAt) {
  final map = haMediaObject(raw);
  HaMediaNode node(Object? value) {
    final row = haMediaObject(value);
    final id = haMediaText(row['media_content_id'], limit: 4096);
    final title = haMediaText(row['title']);
    final type = haMediaText(row['media_content_type'], limit: 128);
    final mediaClass = haMediaText(row['media_class'], limit: 64);
    if (id == null ||
        title == null ||
        type == null ||
        mediaClass == null ||
        row['can_play'] is! bool ||
        row['can_expand'] is! bool) {
      invalidHaMedia();
    }
    haMediaSourceId(id);
    if (row['can_play'] == true &&
        !RegExp(r'^(audio|video)/[a-zA-Z0-9!#&^_.+-]+$').hasMatch(type)) {
      // Unsupported items stay visible but never become playback candidates.
      return HaMediaNode(
        id: id,
        title: title,
        mediaType: type,
        mediaClass: mediaClass,
        canPlay: false,
        canExpand: row['can_expand'] as bool,
      );
    }
    return HaMediaNode(
      id: id,
      title: title,
      mediaType: type,
      mediaClass: mediaClass,
      canPlay: row['can_play'] as bool,
      canExpand: row['can_expand'] as bool,
    );
  }

  final parent = node(map);
  final children = map['children'];
  final notShown = map['not_shown'];
  if (children is! List ||
      children.length > 5000 ||
      (notShown != null &&
          (notShown is! int || notShown < 0 || notShown > 1000000))) {
    invalidHaMedia();
  }
  final ids = <String>{};
  final parsed = <HaMediaNode>[];
  for (final rawChild in children) {
    final child = node(rawChild);
    if (!ids.add(child.id)) invalidHaMedia();
    parsed.add(child);
  }
  return HaMediaBrowsePage(
    parent: parent,
    children: parsed,
    readAt: readAt,
    notShown: notShown as int? ?? 0,
  );
}
