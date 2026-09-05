import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../domain/local_audio_models.dart';

/// Explicit OS selection only. No file path/name, image URI or cloud credentials
/// enter media metadata, preferences, diagnostics, or an automatic fetch.
class LocalAudioArtworkFileAccess {
  Future<Uint8List?> pick() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg'],
    );
    if (file == null) return null;
    return readBounded(
      file.readAsByteStream(),
      declaredLength: await file.length().timeout(const Duration(seconds: 10)),
    );
  }

  static Future<Uint8List> readBounded(
    Stream<List<int>> stream, {
    required int declaredLength,
  }) async {
    if (declaredLength <= 0 ||
        declaredLength > LocalAudioArtwork.maxInputBytes) {
      throw const LocalAudioException(LocalAudioFailure.invalidArtwork);
    }
    // Provider-owned chunks may be reused after delivery.
    final chunks = BytesBuilder();
    final subscription = StreamIterator(stream);
    final expired = Completer<Uint8List>();
    final deadline = Timer(const Duration(seconds: 10), () {
      expired.completeError(TimeoutException('Artwork'));
    });
    Future<Uint8List> consume() async {
      while (!expired.isCompleted && await subscription.moveNext()) {
        final chunk = subscription.current;
        if (chunks.length + chunk.length > LocalAudioArtwork.maxInputBytes) {
          throw const LocalAudioException(LocalAudioFailure.invalidArtwork);
        }
        chunks.add(chunk);
      }
      final bytes = chunks.takeBytes();
      LocalAudioArtwork.validateInput(bytes);
      return bytes;
    }

    try {
      // One deadline race bounds the whole read, including a slow-drip stream,
      // without retaining a timeout listener for every provider chunk.
      return await Future.any([consume(), expired.future]);
    } finally {
      deadline.cancel();
      try {
        await subscription.cancel().timeout(const Duration(seconds: 1));
      } catch (_) {
        // A document provider's stalled cleanup must not hold the picker busy.
      }
    }
  }
}
