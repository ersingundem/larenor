import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/local_audio_models.dart';

/// Method completion means the command was handled, not that sound is audible.
/// Only native snapshots advertise actual playback and available actions.
class LocalAudioBridge {
  LocalAudioBridge({
    MethodChannel? methods,
    EventChannel? events,
    bool? isAndroid,
  }) : _methods = methods ?? const MethodChannel(methodChannelName),
       _events = events ?? const EventChannel(eventChannelName),
       _isAndroid =
           isAndroid ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);
  static const methodChannelName = 'com.ersingundem.larenor/local_audio';
  static const eventChannelName = 'com.ersingundem.larenor/local_audio_events';
  final MethodChannel _methods;
  final EventChannel _events;
  final bool _isAndroid;
  bool _busy = false;

  late final Stream<LocalAudioSnapshot> changes = _isAndroid
      ? _nativeChanges()
      : Stream.multi((sink) {
          sink.add(const LocalAudioSnapshot(supported: false));
          sink.close();
        }, isBroadcast: true);

  Stream<LocalAudioSnapshot> _nativeChanges() {
    final native = _events.receiveBroadcastStream();
    return Stream.multi((sink) {
      StreamSubscription<dynamic>? listener;
      var cancelled = false;
      // EventChannel reports a missing native plugin through FlutterError;
      // establish support through the read-only method before subscribing.
      snapshot().then(
        (initial) {
          if (cancelled) return;
          sink.add(initial);
          if (!initial.supported) {
            sink.close();
            return;
          }
          listener = native.listen(
            (raw) {
              try {
                sink.add(LocalAudioSnapshot.fromChannel(raw));
              } on LocalAudioException catch (error) {
                sink.addError(error);
              }
            },
            onError: (Object error) {
              sink.addError(
                const LocalAudioException(LocalAudioFailure.unavailable),
              );
            },
            onDone: sink.close,
          );
        },
        onError: (Object error) {
          if (!cancelled) {
            sink.addError(
              error is LocalAudioException
                  ? error
                  : const LocalAudioException(LocalAudioFailure.unavailable),
            );
            sink.close();
          }
        },
      );
      sink.onCancel = () {
        cancelled = true;
        return listener?.cancel();
      };
    }, isBroadcast: true);
  }

  Future<LocalAudioSnapshot> snapshot() async {
    if (!_isAndroid) return const LocalAudioSnapshot(supported: false);
    try {
      return LocalAudioSnapshot.fromChannel(
        await _methods.invokeMethod<Object?>('snapshot'),
      );
    } on MissingPluginException {
      return const LocalAudioSnapshot(supported: false);
    } on PlatformException catch (error) {
      throw _safeError(error);
    }
  }

  Future<LocalAudioArtwork> prepareArtwork(Uint8List bytes) async {
    LocalAudioArtwork.validateInput(bytes);
    return _readArtwork('prepareArtwork', Uint8List.fromList(bytes));
  }

  Future<LocalAudioArtwork> artwork({
    required String sourceId,
    required String artworkId,
  }) {
    for (final id in [sourceId, artworkId]) {
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id)) {
        throw const LocalAudioException(LocalAudioFailure.invalidArtwork);
      }
    }
    return _readArtwork('artwork', {
      'sourceId': sourceId,
      'artworkId': artworkId,
    });
  }

  Future<LocalAudioArtwork> _readArtwork(String name, Object payload) async {
    if (!_isAndroid) {
      throw const LocalAudioException(LocalAudioFailure.unsupported);
    }
    try {
      return LocalAudioArtwork.fromChannel(
        await _methods
            .invokeMethod<Object?>(name, payload)
            .timeout(const Duration(seconds: 15)),
      );
    } on MissingPluginException {
      throw const LocalAudioException(LocalAudioFailure.unsupported);
    } on PlatformException catch (error) {
      throw _safeError(error);
    } on TimeoutException {
      throw const LocalAudioException(LocalAudioFailure.unavailable);
    }
  }

  Future<void> play(LocalAudioSource source) =>
      _command('play', payload: source.toChannel());
  Future<void> pause({String? expectedSourceId}) =>
      _command('pause', payload: _controlPayload(expectedSourceId));
  Future<void> resume({String? expectedSourceId}) =>
      _command('resume', payload: _controlPayload(expectedSourceId));
  Future<void> seek(Duration position, {String? expectedSourceId}) {
    if (position.isNegative || position.inMilliseconds > 2592000000) {
      throw const LocalAudioException(LocalAudioFailure.invalidPosition);
    }
    return _command(
      'seek',
      payload: _controlPayload(expectedSourceId, position: position),
    );
  }

  Future<void> stop({String? expectedSourceId}) => _command(
    'stop',
    payload: _controlPayload(expectedSourceId),
    interrupt: true,
  );

  Object? _controlPayload(String? sourceId, {Duration? position}) {
    if (sourceId == null) return position?.inMilliseconds;
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(sourceId)) {
      throw const LocalAudioException(LocalAudioFailure.invalidSource);
    }
    return {
      'sourceId': sourceId,
      if (position != null) 'positionMs': position.inMilliseconds,
    };
  }

  /// Await before starting media_kit video. Unsupported hosts are a no-op;
  /// genuine native stop errors propagate so callers can fail closed.
  Future<void> stopForVideo() async {
    try {
      await stop();
    } on LocalAudioException catch (error) {
      if (error.failure != LocalAudioFailure.unsupported) rethrow;
    }
  }

  Future<void> _command(
    String name, {
    Object? payload,
    bool interrupt = false,
  }) async {
    if (!_isAndroid) {
      throw const LocalAudioException(LocalAudioFailure.unsupported);
    }
    if (_busy && !interrupt) {
      throw const LocalAudioException(LocalAudioFailure.busy);
    }
    if (!interrupt) _busy = true;
    try {
      await _methods.invokeMethod<void>(name, payload);
    } on MissingPluginException {
      throw const LocalAudioException(LocalAudioFailure.unsupported);
    } on PlatformException catch (error) {
      throw _safeError(error);
    } finally {
      if (!interrupt) _busy = false;
    }
  }

  Future<LocalAudioPowerStatus> readPowerStatus() async {
    if (!_isAndroid) return const LocalAudioPowerStatus(supported: false);
    try {
      return LocalAudioPowerStatus.fromChannel(
        await _methods.invokeMethod<Object?>('powerStatus'),
      );
    } on MissingPluginException {
      return const LocalAudioPowerStatus(supported: false);
    } on PlatformException catch (error) {
      throw _safeError(error);
    }
  }

  Future<bool> openBatterySettings() => _openSettings('openBatterySettings');
  Future<bool> openNotificationSettings() =>
      _openSettings('openNotificationSettings');
  Future<bool> _openSettings(String name) async {
    if (!_isAndroid) return false;
    try {
      final result = await _methods.invokeMethod<Object?>(name);
      if (result is! bool) {
        throw const LocalAudioException(LocalAudioFailure.invalidResponse);
      }
      return result;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      throw _safeError(error);
    }
  }

  LocalAudioException _safeError(PlatformException error) =>
      LocalAudioException(
        LocalAudioFailure.values
                .where((value) => value.name == error.code)
                .firstOrNull ??
            LocalAudioFailure.unavailable,
      );
}
