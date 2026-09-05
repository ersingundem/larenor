import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_audio_bridge.dart';
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
