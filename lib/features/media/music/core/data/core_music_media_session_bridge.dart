import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/core_music_playback_models.dart';

enum CoreMusicNativeAction { play, pause, next, previous, seek, volume }

class CoreMusicMediaSessionException implements Exception {
  const CoreMusicMediaSessionException(this.code);
  final String code;

  @override
  String toString() => 'CoreMusicMediaSessionException($code)';
}

class CoreMusicMediaSessionAction {
  const CoreMusicMediaSessionAction({
    required this.sessionId,
    required this.playerRevision,
    required this.action,
    this.value,
  });

  factory CoreMusicMediaSessionAction.fromChannel(Object? value) {
    if (value is! Map<Object?, Object?> ||
        value.length != 4 ||
        !value.keys.every(
          const {'sessionId', 'playerRevision', 'action', 'value'}.contains,
        )) {
      throw const CoreMusicMediaSessionException('invalid_response');
    }
    final sessionId = value['sessionId'];
    final revision = value['playerRevision'];
    final rawAction = value['action'];
    final rawValue = value['value'];
    if (sessionId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(sessionId) ||
        revision is! int ||
        revision < 1 ||
        revision > 0x7fffffffffffffff ||
        rawAction is! String) {
      throw const CoreMusicMediaSessionException('invalid_response');
    }
    final action = CoreMusicNativeAction.values
        .where((item) => item.name == rawAction)
        .firstOrNull;
    if (action == null ||
        (action == CoreMusicNativeAction.seek &&
            (rawValue is! int || rawValue < 0 || rawValue > 604800000)) ||
        (action == CoreMusicNativeAction.volume &&
            (rawValue is! int || rawValue < 0 || rawValue > 100)) ||
        (action != CoreMusicNativeAction.seek &&
            action != CoreMusicNativeAction.volume &&
            rawValue != null)) {
      throw const CoreMusicMediaSessionException('invalid_response');
    }
    return CoreMusicMediaSessionAction(
      sessionId: sessionId,
      playerRevision: revision,
      action: action,
      value: rawValue as int?,
    );
  }

  final String sessionId;
  final int playerRevision;
  final CoreMusicNativeAction action;
  final int? value;

  @override
  String toString() => 'CoreMusicMediaSessionAction(${action.name})';
}

abstract interface class CoreMusicMediaSessionPlatform {
  Stream<CoreMusicMediaSessionAction> get actions;

  Future<void> publish({
    required CoreMusicMediaSessionState state,
    required int playerRevision,
    required bool controlsAuthorized,
    required bool canSeek,
    required bool canVolume,
    required int? volumeLevel,
  });

  Future<void> clear();
}

class CoreMusicMediaSessionBridge implements CoreMusicMediaSessionPlatform {
  CoreMusicMediaSessionBridge({
    MethodChannel? methods,
    EventChannel? events,
    bool? isAndroid,
    String Function()? sessionId,
  }) : _methods = methods ?? const MethodChannel(methodChannelName),
       _events = events ?? const EventChannel(eventChannelName),
       _isAndroid =
           isAndroid ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android),
       _sessionId = sessionId ?? _secureSessionId;

  static const methodChannelName = 'com.ersingundem.larenor/core_music_session';
  static const eventChannelName =
      'com.ersingundem.larenor/core_music_session_actions';

  final MethodChannel _methods;
  final EventChannel _events;
  final bool _isAndroid;
  final String Function() _sessionId;
  String? _activeSessionId;
  String? _activeTargetId;
  int? _activeRevision;

  @override
  late final Stream<CoreMusicMediaSessionAction> actions = _isAndroid
      ? _nativeActions()
      : const Stream<CoreMusicMediaSessionAction>.empty();

  @override
  Future<void> publish({
    required CoreMusicMediaSessionState state,
    required int playerRevision,
    required bool controlsAuthorized,
    required bool canSeek,
    required bool canVolume,
    required int? volumeLevel,
  }) async {
    if (!_isAndroid || !state.active || state.title == null) return;
    if (playerRevision < 1 ||
        playerRevision > 0x7fffffffffffffff ||
        state.positionSeconds < 0 ||
        state.positionSeconds > 604800 ||
        (state.durationSeconds != null &&
            (state.durationSeconds! < state.positionSeconds ||
                state.durationSeconds! > 604800)) ||
        (volumeLevel != null && (volumeLevel < 0 || volumeLevel > 100)) ||
        (canVolume != (volumeLevel != null))) {
      throw const CoreMusicMediaSessionException('invalid_state');
    }
    if (_activeTargetId != state.targetId || _activeSessionId == null) {
      final next = _sessionId();
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(next)) {
        throw const CoreMusicMediaSessionException('invalid_state');
      }
      _activeSessionId = next;
      _activeTargetId = state.targetId;
    }
    final result = await _invoke('publish', {
      'sessionId': _activeSessionId,
      'playerRevision': playerRevision,
      'title': state.title,
      'positionMs': state.positionSeconds * 1000,
      'durationMs': state.durationSeconds == null
          ? null
          : state.durationSeconds! * 1000,
      'isPlaying': state.isPlaying,
      'isGroup': state.isGroup,
      'canPlay': state.canPlay,
      'canPause': state.canPause,
      'canNext': state.canNext,
      'canPrevious': state.canPrevious,
      'canSeek': canSeek,
      'canVolume': canVolume,
      'volumeLevel': volumeLevel,
      'controlsAuthorized': controlsAuthorized,
    });
    if (result != true) {
      throw const CoreMusicMediaSessionException('invalid_response');
    }
    _activeRevision = playerRevision;
  }

  @override
  Future<void> clear() async {
    final sessionId = _activeSessionId;
    _activeSessionId = null;
    _activeTargetId = null;
    _activeRevision = null;
    if (!_isAndroid || sessionId == null) return;
    await _invoke('clear', {'sessionId': sessionId});
  }

  Stream<CoreMusicMediaSessionAction> _nativeActions() {
    return _events.receiveBroadcastStream().transform(
      StreamTransformer.fromHandlers(
        handleData: (value, sink) {
          try {
            final action = CoreMusicMediaSessionAction.fromChannel(value);
            if (action.sessionId != _activeSessionId ||
                action.playerRevision != _activeRevision) {
              throw const CoreMusicMediaSessionException('stale');
            }
            sink.add(action);
          } catch (error) {
            sink.addError(
              error is CoreMusicMediaSessionException
                  ? error
                  : const CoreMusicMediaSessionException('invalid_response'),
            );
          }
        },
      ),
    );
  }

  Future<Object?> _invoke(String method, Object? arguments) async {
    try {
      return await _methods
          .invokeMethod<Object?>(method, arguments)
          .timeout(const Duration(seconds: 5));
    } on MissingPluginException {
      return null;
    } on TimeoutException {
      throw const CoreMusicMediaSessionException('timeout');
    } on PlatformException {
      throw const CoreMusicMediaSessionException('unavailable');
    }
  }

  static String _secureSessionId() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
