enum PlaybackDeliveryMethod { directPlay, remux, transcode }

/// Secret-free, versioned evidence for explaining one server negotiation.
/// File metadata describes the source; it never proves physical HDR/decoder
/// support or measured network capacity.
final class PlaybackQualityEvidence {
  const PlaybackQualityEvidence({
    required this.method,
    required this.sourceContainer,
    required this.targetContainer,
    required this.videoCodec,
    required this.audioCodec,
    required this.subtitleCodec,
    required this.videoRange,
    required this.width,
    required this.height,
    required this.sourceBitrate,
    required this.requestedMaxBitrate,
    required this.reasons,
  });

  static const schemaVersion = 1;
  static const receiverProfile = 'larenor_libmpv_v1';

  factory PlaybackQualityEvidence.fromJellyfinSource(
    Map<String, dynamic> source, {
    required int? requestedMaxBitrate,
  }) {
    final directPlay = source['SupportsDirectPlay'] == true;
    final directStream = source['SupportsDirectStream'] == true;
    final sourceBitrate = _positiveInt(source['Bitrate'], maximum: 1000000000);
    final method = directPlay
        ? PlaybackDeliveryMethod.directPlay
        : directStream &&
              (requestedMaxBitrate == null ||
                  sourceBitrate == null ||
                  sourceBitrate <= requestedMaxBitrate)
        ? PlaybackDeliveryMethod.remux
        : PlaybackDeliveryMethod.transcode;
    final streams = source['MediaStreams'];
    if (streams != null && (streams is! List || streams.length > 128)) {
      throw const FormatException('Invalid Jellyfin media streams');
    }
    Map<String, dynamic>? video;
    Map<String, dynamic>? audio;
    Map<String, dynamic>? subtitle;
    for (final value in streams as List? ?? const []) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Invalid Jellyfin media stream');
      }
      if (value['Type'] == 'Video' && video == null) video = value;
      if (value['Type'] == 'Audio' && audio == null) audio = value;
      if (value['Type'] == 'Subtitle' && subtitle == null) subtitle = value;
    }
    final rawReasons = source['TranscodingReasons'];
    if (rawReasons != null && (rawReasons is! List || rawReasons.length > 16)) {
      throw const FormatException('Invalid Jellyfin transcoding reasons');
    }
    final reasons = <String>[];
    for (final value in rawReasons as List? ?? const []) {
      final reason = _token(value, maximum: 64);
      if (reason == null) {
        throw const FormatException('Invalid Jellyfin transcoding reason');
      }
      if (!reasons.contains(reason)) reasons.add(reason);
    }
    if (method == PlaybackDeliveryMethod.transcode &&
        requestedMaxBitrate != null &&
        sourceBitrate != null &&
        sourceBitrate > requestedMaxBitrate &&
        !reasons.contains('bitrate_limit')) {
      reasons.add('bitrate_limit');
    }
    return PlaybackQualityEvidence(
      method: method,
      sourceContainer: _token(source['Container'], maximum: 32),
      targetContainer: _token(source['TranscodingContainer'], maximum: 32),
      videoCodec: _token(video?['Codec'], maximum: 32),
      audioCodec: _token(audio?['Codec'], maximum: 32),
      subtitleCodec: _token(subtitle?['Codec'], maximum: 32),
      videoRange: _token(video?['VideoRange'], maximum: 32),
      width: _positiveInt(video?['Width'], maximum: 32768),
      height: _positiveInt(video?['Height'], maximum: 32768),
      sourceBitrate: sourceBitrate,
      requestedMaxBitrate: requestedMaxBitrate,
      reasons: List.unmodifiable(reasons),
    );
  }

  final PlaybackDeliveryMethod method;
  final String? sourceContainer;
  final String? targetContainer;
  final String? videoCodec;
  final String? audioCodec;
  final String? subtitleCodec;
  final String? videoRange;
  final int? width;
  final int? height;
  final int? sourceBitrate;
  final int? requestedMaxBitrate;
  final List<String> reasons;

  bool get hasMeasuredNetworkEvidence => false;
  bool get hasPhysicalDecoderEvidence => false;

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'method': method.name,
    'receiverProfile': receiverProfile,
    'sourceContainer': ?sourceContainer,
    'targetContainer': ?targetContainer,
    'videoCodec': ?videoCodec,
    'audioCodec': ?audioCodec,
    'subtitleCodec': ?subtitleCodec,
    'videoRange': ?videoRange,
    'width': ?width,
    'height': ?height,
    'sourceBitrate': ?sourceBitrate,
    'requestedMaxBitrate': ?requestedMaxBitrate,
    'reasons': reasons,
    'hasMeasuredNetworkEvidence': hasMeasuredNetworkEvidence,
    'hasPhysicalDecoderEvidence': hasPhysicalDecoderEvidence,
  };

  static int? _positiveInt(Object? value, {required int maximum}) {
    if (value == null) return null;
    if (value is! num || !value.isFinite || value != value.roundToDouble()) {
      throw const FormatException('Invalid Jellyfin bitrate');
    }
    final result = value.toInt();
    if (result < 1 || result > maximum) {
      throw const FormatException('Invalid Jellyfin bitrate');
    }
    return result;
  }

  static String? _token(Object? value, {required int maximum}) {
    if (value == null) return null;
    if (value is! String) return null;
    final result = value.trim().toLowerCase();
    if (result.isEmpty ||
        result.length > maximum ||
        !RegExp(r'^[a-z0-9_.+-]+$').hasMatch(result)) {
      return null;
    }
    return result;
  }
}
