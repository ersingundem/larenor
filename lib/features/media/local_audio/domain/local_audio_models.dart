import 'local_audio_artwork.dart';

export 'local_audio_artwork.dart';

enum LocalAudioPhase { idle, loading, ready, ended, error }

enum LocalAudioMediaKind { music, audiobook, podcast }

enum LocalAudioFailure {
  unsupported,
  invalidSource,
  invalidArtwork,
  invalidPosition,
  invalidSleepTimer,
  foregroundRequired,
  busy,
  unavailable,
  network,
  unsupportedFormat,
  audioOutput,
  invalidResponse,
}

class LocalAudioException implements Exception {
  const LocalAudioException(this.failure);
  final LocalAudioFailure failure;
  @override
  String toString() => 'Local audio operation unavailable';
}

/// Anonymous, explicitly chosen audio only. No source URI appears in playback
/// snapshots, persisted state, diagnostic output, or public media IDs.
class LocalAudioSource {
  factory LocalAudioSource({
    required String id,
    required Uri uri,
    required String mimeType,
    required String title,
    String? artist,
    String? album,
    LocalAudioArtwork? artwork,
    LocalAudioMediaKind mediaKind = LocalAudioMediaKind.music,
    Duration initialPosition = Duration.zero,
    Duration? sleepTimer,
  }) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id) ||
        !mimeTypes.contains(mimeType)) {
      throw const LocalAudioException(LocalAudioFailure.invalidSource);
    }
    validateUri(uri);
    _sourceText(title);
    if (artist != null) _sourceText(artist);
    if (album != null) _sourceText(album);
    if (initialPosition.isNegative ||
        initialPosition.inMilliseconds > 2592000000 ||
        (sleepTimer != null &&
            (sleepTimer.inMilliseconds % 1000 != 0 ||
                sleepTimer.inSeconds < 60 ||
                sleepTimer.inSeconds > 86400))) {
      throw const LocalAudioException(LocalAudioFailure.invalidSource);
    }
    return LocalAudioSource._(
      id,
      uri,
      mimeType,
      title,
      artist,
      album,
      artwork,
      mediaKind,
      initialPosition,
      sleepTimer,
    );
  }
  const LocalAudioSource._(
    this.id,
    this.uri,
    this.mimeType,
    this.title,
    this.artist,
    this.album,
    this.artwork,
    this.mediaKind,
    this.initialPosition,
    this.sleepTimer,
  );
  static const mimeTypes = {
    'audio/mpeg',
    'audio/aac',
    'audio/mp4',
    'audio/ogg',
    'audio/flac',
    'audio/wav',
  };
  final String id, mimeType, title;
  final Uri uri;
  final String? artist, album;
  final LocalAudioArtwork? artwork;
  final LocalAudioMediaKind mediaKind;
  final Duration initialPosition;
  final Duration? sleepTimer;

  static void validateUri(Uri uri) {
    final value = uri.toString();
    if (!{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.port < 1 ||
        uri.port > 65535 ||
        value.length > 2048 ||
        value.contains('\\') ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(value) ||
        RegExp(
          r'%0[0-9a-f]|%1[0-9a-f]|%7f',
          caseSensitive: false,
        ).hasMatch(value) ||
        // Uri normalizes some invalid authority forms; reject encoded userinfo.
        uri.authority.contains('@')) {
      throw const LocalAudioException(LocalAudioFailure.invalidSource);
    }
  }

  static void _sourceText(String value) {
    if (value.trim().isEmpty ||
        value.length > 256 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw const LocalAudioException(LocalAudioFailure.invalidSource);
    }
  }

  Map<String, Object?> toChannel() => {
    'id': id,
    'uri': uri.toString(),
    'mimeType': mimeType,
    'title': title,
    'artist': artist,
    'album': album,
    'mediaKind': mediaKind.name,
    'initialPositionMs': initialPosition.inMilliseconds,
    if (sleepTimer != null) 'sleepTimerSeconds': sleepTimer!.inSeconds,
    if (artwork != null) 'artworkBytes': artwork!.bytes,
  };
  @override
  String toString() => 'LocalAudioSource(redacted)';
}

class LocalAudioSnapshot {
  const LocalAudioSnapshot({
    required this.supported,
    this.phase = LocalAudioPhase.idle,
    this.sourceId,
    this.title,
    this.artist,
    this.album,
    this.isPlaying = false,
    this.position,
    this.duration,
    this.canPlay = false,
    this.canPause = false,
    this.canSeek = false,
    this.canStop = false,
    this.failure,
    this.artworkState = LocalAudioArtworkState.none,
    this.artworkId,
    this.mediaKind = LocalAudioMediaKind.music,
    this.sleepTimerEndsAt,
  });
  factory LocalAudioSnapshot.fromChannel(Object? value) {
    final data = _map(value);
    final supported = _bool(data, 'supported');
    if (!supported) return const LocalAudioSnapshot(supported: false);
    final phase = LocalAudioPhase.values
        .where((v) => v.name == data['phase'])
        .firstOrNull;
    if (phase == null) _invalid();
    final source = _text(data['sourceId'], 128);
    if (source != null && !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(source)) {
      _invalid();
    }
    final artworkState = LocalAudioArtworkState.values
        .where((v) => v.name == (data['artworkState'] ?? 'none'))
        .firstOrNull;
    final artworkId = _text(data['artworkId'], 128);
    if (artworkState == null ||
        (artworkId != null &&
            !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(artworkId)) ||
        ((artworkState == LocalAudioArtworkState.ready) !=
            (artworkId != null)) ||
        (artworkState != LocalAudioArtworkState.none && source == null)) {
      _invalid();
    }
    final position = _duration(data['positionMs']);
    final duration = _duration(data['durationMs']);
    final playing = _bool(data, 'isPlaying');
    final canPlay = _bool(data, 'canPlay');
    final canPause = _bool(data, 'canPause');
    final canSeek = _bool(data, 'canSeek');
    final canStop = _bool(data, 'canStop');
    final mediaKind = LocalAudioMediaKind.values
        .where((kind) => kind.name == (data['mediaKind'] ?? 'music'))
        .firstOrNull;
    final sleepTimerEndsAt = _dateTime(data['sleepTimerEndsAtMs']);
    if ((playing && (source == null || phase != LocalAudioPhase.ready)) ||
        (canSeek && (duration == null || source == null)) ||
        ((canPlay || canPause) && source == null) ||
        (duration != null && duration == Duration.zero) ||
        mediaKind == null ||
        (sleepTimerEndsAt != null && source == null)) {
      _invalid();
    }
    return LocalAudioSnapshot(
      supported: true,
      phase: phase,
      sourceId: source,
      title: _text(data['title'], 256),
      artist: _text(data['artist'], 256),
      album: _text(data['album'], 256),
      isPlaying: playing,
      position: position,
      duration: duration,
      canPlay: canPlay,
      canPause: canPause,
      canSeek: canSeek,
      canStop: canStop,
      failure: _failure(data['failure']),
      artworkState: artworkState,
      artworkId: artworkId,
      mediaKind: mediaKind,
      sleepTimerEndsAt: sleepTimerEndsAt,
    );
  }
  final bool supported, isPlaying, canPlay, canPause, canSeek, canStop;
  final LocalAudioPhase phase;
  final String? sourceId, title, artist, album;
  final Duration? position, duration;
  final LocalAudioFailure? failure;
  final LocalAudioArtworkState artworkState;
  final String? artworkId;
  final LocalAudioMediaKind mediaKind;
  final DateTime? sleepTimerEndsAt;
}

class LocalAudioPowerStatus {
  const LocalAudioPowerStatus({
    required this.supported,
    this.sdkInt,
    this.notificationsEnabled,
    this.notificationPermissionGranted,
    this.mediaNotificationExempt,
    this.batteryOptimizationExempt,
    this.backgroundRestricted,
  });
  factory LocalAudioPowerStatus.fromChannel(Object? value) {
    final data = _map(value);
    if (!_bool(data, 'supported')) {
      return const LocalAudioPowerStatus(supported: false);
    }
    final sdk = data['sdkInt'];
    if (sdk is! int || sdk < 23 || sdk > 100) _invalid();
    return LocalAudioPowerStatus(
      supported: true,
      sdkInt: sdk,
      notificationsEnabled: _bool(data, 'notificationsEnabled'),
      notificationPermissionGranted: _bool(
        data,
        'notificationPermissionGranted',
      ),
      mediaNotificationExempt: _bool(data, 'mediaNotificationExempt'),
      batteryOptimizationExempt: _bool(data, 'batteryOptimizationExempt'),
      backgroundRestricted: _bool(data, 'backgroundRestricted'),
    );
  }
  final bool supported;
  final int? sdkInt;
  final bool? notificationsEnabled,
      notificationPermissionGranted,
      mediaNotificationExempt,
      batteryOptimizationExempt,
      backgroundRestricted;
}

Never _invalid() =>
    throw const LocalAudioException(LocalAudioFailure.invalidResponse);
Map<Object?, Object?> _map(Object? value) {
  if (value is! Map ||
      value.length > 24 ||
      value.keys.any((key) => key is! String) ||
      value.keys.any(
        (key) => {
          'uri',
          'url',
          'headers',
          'token',
          'bytes',
          'artworkBytes',
          'artworkUri',
        }.contains(key),
      )) {
    _invalid();
  }
  return value;
}

bool _bool(Map<Object?, Object?> data, String key) {
  final value = data[key];
  if (value is! bool) _invalid();
  return value;
}

String? _text(Object? value, int limit) {
  if (value == null) return null;
  if (value is! String ||
      value.isEmpty ||
      value.length > limit ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    _invalid();
  }
  return value;
}

Duration? _duration(Object? value) {
  if (value == null) return null;
  if (value is! int || value < 0 || value > 2592000000) _invalid();
  return Duration(milliseconds: value);
}

DateTime? _dateTime(Object? value) {
  if (value == null) return null;
  if (value is! int || value < 0 || value > 4102444800000) _invalid();
  return DateTime.fromMillisecondsSinceEpoch(value);
}

LocalAudioFailure? _failure(Object? value) {
  if (value == null) return null;
  final result = LocalAudioFailure.values
      .where((v) => v.name == value)
      .firstOrNull;
  if (result == null) _invalid();
  return result;
}
