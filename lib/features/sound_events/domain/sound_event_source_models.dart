import 'package:flutter/foundation.dart';

@immutable
final class SoundSourceChoice {
  const SoundSourceChoice({
    required this.id,
    required this.revision,
    required this.label,
    required this.audioLabels,
  });
  final String id, label;
  final int revision;
  final List<String> audioLabels;
}

@immutable
final class SoundSourceConfiguration {
  const SoundSourceConfiguration({
    required this.revision,
    required this.cameraResourceId,
    required this.cameraRevision,
    required this.roomId,
    required this.roomRevision,
    required this.labels,
    required this.consentGranted,
    required this.retentionSeconds,
  });
  final int revision, cameraRevision, roomRevision, retentionSeconds;
  final String cameraResourceId, roomId;
  final Map<String, List<String>> labels;
  final bool consentGranted;
}

@immutable
final class SoundSourceSetup {
  const SoundSourceSetup({
    required this.revision,
    required this.discoveryVerified,
    required this.configuration,
    required this.cameras,
    required this.rooms,
  });
  final int revision;
  final bool discoveryVerified;
  final SoundSourceConfiguration? configuration;
  final List<SoundSourceChoice> cameras, rooms;
}
