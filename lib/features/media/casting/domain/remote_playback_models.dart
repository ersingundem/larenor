const remoteMaximumPositionTicks = 25920000000000; // 30 days, 100ns ticks.

/// The application only controls freshly discovered, authenticated same-user
/// sessions. A display name is never a target identity.
class RemotePlaybackTarget {
  RemotePlaybackTarget({
    required this.sessionId,
    required this.deviceId,
    required this.userId,
    required this.serverId,
    required this.name,
    required this.client,
    required this.isActive,
    required this.supportsRemoteControl,
    required this.supportsMediaControl,
    required Set<String> playableMediaTypes,
    this.nowPlayingItemId,
    this.isPaused,
    this.positionTicks,
    this.lastPlaybackCheckIn,
  }) : playableMediaTypes = Set.unmodifiable(playableMediaTypes);
  final String sessionId;
  final String? deviceId, userId, serverId;
  final String name, client;
  final bool isActive, supportsRemoteControl, supportsMediaControl;
  final Set<String> playableMediaTypes;
  final String? nowPlayingItemId;
  final bool? isPaused;
  final int? positionTicks;
  final DateTime? lastPlaybackCheckIn;

  bool eligibleFor({required String userId, required String localDeviceId}) =>
      isActive &&
      supportsRemoteControl &&
      supportsMediaControl &&
      playableMediaTypes.contains('Video') &&
      this.userId == userId &&
      deviceId != null &&
      deviceId != localDeviceId &&
      serverId != null;

  bool sameIdentity(RemotePlaybackTarget other) =>
      sessionId == other.sessionId &&
      deviceId == other.deviceId &&
      userId == other.userId &&
      serverId == other.serverId;
}

enum RemotePlaybackFailure {
  authentication,
  permission,
  transport,
  timeout,
  invalidResponse,
  unavailable,
  unsupportedItem,
  invalidIntent,
  expiredIntent,
  busy,
}

enum RemotePlaybackReceiptStatus { accepted, observed, unconfirmed }

class RemotePlaybackReceipt {
  const RemotePlaybackReceipt({
    required this.status,
    required this.target,
    required this.itemId,
    required this.acceptedAt,
    this.observedAt,
  });
  final RemotePlaybackReceiptStatus status;
  final RemotePlaybackTarget target;
  final String itemId;
  final DateTime acceptedAt;
  final DateTime? observedAt;
}

class RemotePlaybackSnapshot {
  RemotePlaybackSnapshot({
    this.configured = true,
    this.isLoading = false,
    this.isBusy = false,
    this.outcomeUnknown = false,
    List<RemotePlaybackTarget> targets = const [],
    this.readAt,
    this.failure,
    this.receipt,
  }) : targets = List.unmodifiable(targets);
  final bool configured, isLoading, isBusy, outcomeUnknown;
  final List<RemotePlaybackTarget> targets;
  final DateTime? readAt;
  final RemotePlaybackFailure? failure;
  final RemotePlaybackReceipt? receipt;
}

class RemotePlaybackException implements Exception {
  const RemotePlaybackException(this.failure, {this.outcomeUnknown = false});
  final bool outcomeUnknown;
  final RemotePlaybackFailure failure;
  @override
  String toString() => 'Remote playback could not be completed';
}

String remoteItemId(String value) {
  final normalized = value.replaceAll('-', '').toLowerCase();
  if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(normalized) ||
      !RegExp(
        r'^(?:[a-fA-F0-9]{32}|[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12})$',
      ).hasMatch(value)) {
    throw const RemotePlaybackException(RemotePlaybackFailure.invalidResponse);
  }
  return normalized;
}

String remoteSessionId(String value) {
  if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(value)) {
    throw const RemotePlaybackException(RemotePlaybackFailure.invalidResponse);
  }
  return value;
}

List<RemotePlaybackTarget> parseRemotePlaybackTargets(Object? raw) {
  Never invalid() => throw const RemotePlaybackException(
    RemotePlaybackFailure.invalidResponse,
  );
  if (raw is! List || raw.length > 256) invalid();
  final ids = <String>{};
  final result = <RemotePlaybackTarget>[];
  String? text(Object? value, {int limit = 256}) {
    if (value == null) return null;
    if (value is! String ||
        value.length > limit ||
        value.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      invalid();
    }
    return value.isEmpty ? null : value;
  }

  bool? boolean(Object? value) {
    if (value != null && value is! bool) invalid();
    return value as bool?;
  }

  Map<String, dynamic>? object(Object? value) {
    if (value == null) return null;
    if (value is! Map ||
        value.length > 128 ||
        value.keys.any((key) => key is! String)) {
      invalid();
    }
    return Map<String, dynamic>.from(value);
  }

  for (final entry in raw) {
    final row = object(entry);
    if (row == null) invalid();
    final id = remoteSessionId(text(row['Id']) ?? '');
    if (!ids.add(id)) invalid();
    final types = row['PlayableMediaTypes'];
    if (types != null &&
        (types is! List ||
            types.length > 16 ||
            types.any((value) => value is! String || value.length > 32))) {
      invalid();
    }
    final play = object(row['PlayState']);
    final item = object(row['NowPlayingItem']);
    final ticks = play?['PositionTicks'];
    if (ticks != null &&
        (ticks is! int || ticks < 0 || ticks > remoteMaximumPositionTicks)) {
      invalid();
    }
    final checkIn = text(row['LastPlaybackCheckIn']);
    final timestamp = checkIn == null ? null : DateTime.tryParse(checkIn);
    if (checkIn != null &&
        (timestamp == null ||
            !RegExp(r'(?:Z|[+-]\d{2}:\d{2})$').hasMatch(checkIn))) {
      invalid();
    }
    final user = text(row['UserId']);
    final itemId = text(item?['Id']);
    result.add(
      RemotePlaybackTarget(
        sessionId: id,
        deviceId: text(row['DeviceId']),
        userId: user == null ? null : remoteItemId(user),
        serverId: text(row['ServerId']),
        name: text(row['DeviceName'], limit: 512) ?? id,
        client: text(row['Client']) ?? '',
        isActive: boolean(row['IsActive']) == true,
        supportsRemoteControl: boolean(row['SupportsRemoteControl']) == true,
        supportsMediaControl: boolean(row['SupportsMediaControl']) == true,
        playableMediaTypes: types == null
            ? {}
            : (types as List).cast<String>().toSet(),
        nowPlayingItemId: itemId == null ? null : remoteItemId(itemId),
        isPaused: boolean(play?['IsPaused']),
        positionTicks: ticks as int?,
        lastPlaybackCheckIn: timestamp?.toUtc(),
      ),
    );
  }
  result.sort((a, b) => a.sessionId.compareTo(b.sessionId));
  return List.unmodifiable(result);
}
