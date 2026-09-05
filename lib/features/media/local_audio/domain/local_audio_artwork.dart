import 'dart:typed_data';

import 'local_audio_models.dart';

enum LocalAudioArtworkState { none, loading, ready, failed }

/// Pixel-only JPEG returned by the native decoder, never a path or remote URL.
/// Copies at both boundaries prevent a caller changing an approved play payload.
class LocalAudioArtwork {
  LocalAudioArtwork._(Uint8List bytes, this.width, this.height)
    : _bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  factory LocalAudioArtwork.fromChannel(Object? raw) {
    if (raw is! Map ||
        raw.length != 3 ||
        !raw.keys.toSet().containsAll(['bytes', 'width', 'height'])) {
      throw const LocalAudioException(LocalAudioFailure.invalidArtwork);
    }
    final bytes = raw['bytes'];
    final width = raw['width'];
    final height = raw['height'];
    if (bytes is! Uint8List ||
        bytes.length < 3 ||
        bytes.length > maxOutputBytes ||
        bytes[0] != 0xff ||
        bytes[1] != 0xd8 ||
        bytes[2] != 0xff ||
        width is! int ||
        width < 1 ||
        width > maxDimension ||
        height is! int ||
        height < 1 ||
        height > maxDimension) {
      throw const LocalAudioException(LocalAudioFailure.invalidArtwork);
    }
    return LocalAudioArtwork._(bytes, width, height);
  }
  static const maxInputBytes = 1024 * 1024;
  static const maxOutputBytes = 128 * 1024;
  static const maxDimension = 512;
  final Uint8List _bytes;
  final int width, height;
  Uint8List get bytes => _bytes;

  static void validateInput(Uint8List bytes) {
    const png = [137, 80, 78, 71, 13, 10, 26, 10];
    final isPng =
        bytes.length >= 8 &&
        Iterable<int>.generate(8).every((i) => bytes[i] == png[i]);
    final isJpeg =
        bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
    if (bytes.isEmpty || bytes.length > maxInputBytes || (!isPng && !isJpeg)) {
      throw const LocalAudioException(LocalAudioFailure.invalidArtwork);
    }
  }

  @override
  String toString() => 'LocalAudioArtwork(redacted)';
}
