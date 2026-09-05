import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_audio_bridge.dart';
import '../data/local_audio_artwork_file_access.dart';
import '../domain/local_audio_models.dart';

final localAudioBridgeProvider = Provider<LocalAudioBridge>(
  (ref) => LocalAudioBridge(),
);

/// UI subscription lifetime never controls the independently owned native audio
/// service. Opening this provider does not select media or start that service.
final localAudioProvider = StreamProvider.autoDispose<LocalAudioSnapshot>(
  (ref) => ref.watch(localAudioBridgeProvider).changes,
  retry: (_, _) => null,
);

/// Identity changes create a different family. A position tick reuses the same
/// small image and never transfers bytes repeatedly over the platform channel.
final localAudioArtworkProvider = FutureProvider.autoDispose
    .family<LocalAudioArtwork, ({String sourceId, String artworkId})>((
      ref,
      id,
    ) async {
      final bridge = ref.watch(localAudioBridgeProvider);
      final result = await bridge.artwork(
        sourceId: id.sourceId,
        artworkId: id.artworkId,
      );
      if (!ref.mounted) {
        throw const LocalAudioException(LocalAudioFailure.unavailable);
      }
      // Native checks atomically too; a result already in transit must not
      // survive replacing or clearing the source during this await.
      final current = await bridge.snapshot();
      if (!ref.mounted ||
          current.sourceId != id.sourceId ||
          current.artworkId != id.artworkId ||
          current.artworkState != LocalAudioArtworkState.ready) {
        throw const LocalAudioException(LocalAudioFailure.unavailable);
      }
      return result;
    }, retry: (_, _) => null);

final localAudioArtworkFileAccessProvider =
    Provider<LocalAudioArtworkFileAccess>(
      (ref) => LocalAudioArtworkFileAccess(),
    );
