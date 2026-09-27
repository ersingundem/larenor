import '../../jellyfin/data/jellyfin_client.dart';
import '../../jellyfin/domain/playback_quality_advisor.dart';
import '../domain/core_playback_quality_advice.dart';
import 'android_playback_capability_port.dart';

final class CorePlaybackQualityRequestAdapter {
  const CorePlaybackQualityRequestAdapter._();

  static CorePlaybackQualityRequest localAndroid(
    JellyfinPlaybackSource source,
    AndroidPlaybackCapabilitySnapshot? platform,
  ) {
    final media = source.qualityEvidence;
    return CorePlaybackQualityRequest(
      media: media == null
          ? CorePlaybackMediaEvidence(
              state: CorePlaybackEvidenceState.unknown,
              sourceId: source.mediaSourceId,
              container: null,
              videoCodec: null,
              audioCodec: null,
              subtitleCodec: null,
              bitrateBps: null,
              width: null,
              height: null,
              hdr: null,
              serverDecision: CorePlaybackMethod.unknown,
              transcodeReasons: const [],
            )
          : _media(source.mediaSourceId, media),
      receiver: _receiver(platform),
      network: _network(platform),
    );
  }

  static CorePlaybackMediaEvidence _media(
    String sourceId,
    PlaybackQualityEvidence evidence,
  ) {
    final completeDimensions =
        evidence.width != null && evidence.height != null;
    return CorePlaybackMediaEvidence(
      state: CorePlaybackEvidenceState.reported,
      sourceId: sourceId,
      container: evidence.sourceContainer,
      videoCodec: evidence.videoCodec,
      audioCodec: evidence.audioCodec,
      subtitleCodec: evidence.subtitleCodec,
      bitrateBps: evidence.sourceBitrate,
      width: completeDimensions ? evidence.width : null,
      height: completeDimensions ? evidence.height : null,
      hdr: _mediaHdr(evidence.videoRange),
      serverDecision: switch (evidence.method) {
        PlaybackDeliveryMethod.directPlay => CorePlaybackMethod.directPlay,
        PlaybackDeliveryMethod.remux => CorePlaybackMethod.remux,
        PlaybackDeliveryMethod.transcode => CorePlaybackMethod.transcode,
      },
      transcodeReasons: _transcodeReasons(evidence),
    );
  }

  static CorePlaybackReceiverEvidence _receiver(
    AndroidPlaybackCapabilitySnapshot? snapshot,
  ) {
    if (snapshot == null) return const CorePlaybackReceiverEvidence.unknown();
    final mimeTypes = snapshot.decoderMimeTypes;
    final video = <String>[];
    final audio = <String>[];
    for (final mime in mimeTypes ?? const <String>[]) {
      final target = mime.startsWith('video/')
          ? video
          : mime.startsWith('audio/')
          ? audio
          : null;
      final codec = _codecFromMime(mime);
      if (target != null && codec != null && !target.contains(codec)) {
        target.add(codec);
      }
    }
    video.sort();
    audio.sort();
    final hdr = <CorePlaybackHdr>[];
    for (final value in snapshot.displayHdrTypes ?? const <String>[]) {
      final mapped = switch (value) {
        'dolbyVision' => CorePlaybackHdr.dolbyVision,
        'hdr10' => CorePlaybackHdr.hdr10,
        'hdr10Plus' => CorePlaybackHdr.hdr10Plus,
        'hlg' || 'hlgPlus' => CorePlaybackHdr.hlg,
        _ => null,
      };
      if (mapped != null && !hdr.contains(mapped)) hdr.add(mapped);
    }
    final completeDimensions =
        snapshot.displayWidthPixels != null &&
        snapshot.displayHeightPixels != null;
    final hasEvidence =
        video.isNotEmpty ||
        audio.isNotEmpty ||
        hdr.isNotEmpty ||
        completeDimensions;
    if (!hasEvidence) return const CorePlaybackReceiverEvidence.unknown();
    return CorePlaybackReceiverEvidence(
      state: CorePlaybackEvidenceState.reported,
      videoCodecs: List.unmodifiable(video.take(32)),
      audioCodecs: List.unmodifiable(audio.take(32)),
      subtitleFormats: const [],
      maxWidth: completeDimensions ? snapshot.displayWidthPixels : null,
      maxHeight: completeDimensions ? snapshot.displayHeightPixels : null,
      hdrTypes: List.unmodifiable(hdr.take(6)),
    );
  }

  static CorePlaybackNetworkEvidence _network(
    AndroidPlaybackCapabilitySnapshot? snapshot,
  ) {
    final transports = snapshot?.networkTransports;
    final hasEvidence =
        transports != null ||
        snapshot?.networkDownstreamKbps != null ||
        snapshot?.networkMetered != null;
    if (!hasEvidence) return const CorePlaybackNetworkEvidence.unknown();
    return CorePlaybackNetworkEvidence(
      // Android reports link properties. Even VALIDATED is not a measured
      // playback throughput result, so this evidence remains reported.
      state: CorePlaybackEvidenceState.reported,
      transport: _transport(transports ?? const []),
      downstreamKbps: snapshot?.networkDownstreamKbps,
      metered: snapshot?.networkMetered,
    );
  }

  static String? _codecFromMime(String mime) {
    const canonical = {
      'video/avc': 'h264',
      'video/hevc': 'hevc',
      'video/av01': 'av1',
      'video/x-vnd.on2.vp9': 'vp9',
      'video/x-vnd.on2.vp8': 'vp8',
      'audio/mp4a-latm': 'aac',
      'audio/ac3': 'ac3',
      'audio/eac3': 'eac3',
      'audio/eac3-joc': 'eac3',
      'audio/opus': 'opus',
      'audio/vorbis': 'vorbis',
      'audio/flac': 'flac',
    };
    final known = canonical[mime];
    if (known != null) return known;
    final separator = mime.indexOf('/');
    if (separator < 1 || separator == mime.length - 1) return null;
    final subtype = mime.substring(separator + 1);
    return RegExp(r'^[a-z0-9][a-z0-9._+-]{0,63}$').hasMatch(subtype)
        ? subtype
        : null;
  }

  static CorePlaybackTransport? _transport(List<String> transports) {
    for (final preferred in const ['vpn', 'ethernet', 'wifi', 'cellular']) {
      if (transports.contains(preferred)) {
        return switch (preferred) {
          'vpn' => CorePlaybackTransport.vpn,
          'ethernet' => CorePlaybackTransport.ethernet,
          'wifi' => CorePlaybackTransport.wifi,
          'cellular' => CorePlaybackTransport.cellular,
          _ => null,
        };
      }
    }
    return transports.isEmpty ? null : CorePlaybackTransport.other;
  }

  static CorePlaybackHdr? _mediaHdr(String? value) {
    if (value == null) return null;
    final compact = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return switch (compact) {
      'sdr' => CorePlaybackHdr.sdr,
      'hdr10' => CorePlaybackHdr.hdr10,
      'hdr10plus' => CorePlaybackHdr.hdr10Plus,
      'dv' || 'dovi' || 'dolbyvision' => CorePlaybackHdr.dolbyVision,
      'hlg' => CorePlaybackHdr.hlg,
      _ => CorePlaybackHdr.unknown,
    };
  }

  static List<CorePlaybackTranscodeReason> _transcodeReasons(
    PlaybackQualityEvidence evidence,
  ) {
    if (evidence.method == PlaybackDeliveryMethod.directPlay) return const [];
    final result = <CorePlaybackTranscodeReason>[];
    for (final raw in evidence.reasons) {
      final compact = raw.replaceAll(RegExp(r'[^a-z0-9]'), '');
      final value = compact.contains('container')
          ? CorePlaybackTranscodeReason.container
          : compact.contains('videocodec')
          ? CorePlaybackTranscodeReason.videoCodec
          : compact.contains('audiocodec')
          ? CorePlaybackTranscodeReason.audioCodec
          : compact.contains('subtitle')
          ? CorePlaybackTranscodeReason.subtitle
          : compact.contains('bitrate')
          ? CorePlaybackTranscodeReason.bitrate
          : compact.contains('resolution')
          ? CorePlaybackTranscodeReason.resolution
          : compact.contains('hdr')
          ? CorePlaybackTranscodeReason.hdr
          : compact.contains('network')
          ? CorePlaybackTranscodeReason.network
          : compact.contains('receiver')
          ? CorePlaybackTranscodeReason.receiver
          : CorePlaybackTranscodeReason.unknown;
      if (!result.contains(value)) result.add(value);
    }
    return List.unmodifiable(result.take(10));
  }
}
