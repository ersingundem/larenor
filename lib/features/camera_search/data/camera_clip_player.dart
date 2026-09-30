import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Native playback is injectable only at the rendering boundary in widget tests.
abstract interface class CameraClipPlayer {
  Stream<bool> get playing;
  Stream<bool> get buffering;
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<String> get errors;
  Widget surface();
  Future<void> open(String uri);
  Future<void> toggle();
  Future<void> seek(Duration position);
  Future<void> dispose();
}

final class MediaKitCameraClipPlayer implements CameraClipPlayer {
  final Player _player = Player();
  late final VideoController _video = VideoController(_player);
  @override
  Stream<bool> get playing => _player.stream.playing;
  @override
  Stream<bool> get buffering => _player.stream.buffering;
  @override
  Stream<Duration> get position => _player.stream.position;
  @override
  Stream<Duration> get duration => _player.stream.duration;
  @override
  Stream<String> get errors => _player.stream.error;
  @override
  Widget surface() =>
      Video(controller: _video, controls: null, fit: BoxFit.contain);
  @override
  Future<void> open(String uri) => _player.open(Media(uri));
  @override
  Future<void> toggle() => _player.playOrPause();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> dispose() => _player.dispose();
}
