import '../../../server/domain/server_models.dart';

enum CorePlaybackEvidenceState { reported, verified, unknown }

enum CorePlaybackMethod { directPlay, remux, transcode, unknown }

enum CorePlaybackHdr { sdr, hdr10, hdr10Plus, dolbyVision, hlg, unknown }

enum CorePlaybackTransport { wifi, ethernet, cellular, vpn, other, offline }

enum CorePlaybackTranscodeReason {
  container,
  videoCodec,
  audioCodec,
  subtitle,
  bitrate,
  resolution,
  hdr,
  network,
  receiver,
  unknown,
}

enum CorePlaybackRecommendationCode {
  keepOriginal,
  lowerBitrate,
  preferCompatibleAudio,
  preferExternalSubtitle,
  inspectReceiver,
  measureNetwork,
  verifyHdrOnDevice,
}

enum CorePlaybackProcessingLoad { low, medium, high, unknown }

final class CorePlaybackMediaEvidence {
  const CorePlaybackMediaEvidence({
    required this.state,
    required this.sourceId,
    required this.container,
    required this.videoCodec,
    required this.audioCodec,
    required this.subtitleCodec,
    required this.bitrateBps,
    required this.width,
    required this.height,
    required this.hdr,
    required this.serverDecision,
    required this.transcodeReasons,
  });

  final CorePlaybackEvidenceState state;
  final String sourceId;
  final String? container;
  final String? videoCodec;
  final String? audioCodec;
  final String? subtitleCodec;
  final int? bitrateBps;
  final int? width;
  final int? height;
  final CorePlaybackHdr? hdr;
  final CorePlaybackMethod serverDecision;
  final List<CorePlaybackTranscodeReason> transcodeReasons;

  Map<String, Object?> toJson() => {
    'state': state.name,
    'sourceId': sourceId,
    'container': container,
    'videoCodec': videoCodec,
    'audioCodec': audioCodec,
    'subtitleCodec': subtitleCodec,
    'bitrateBps': bitrateBps,
    'width': width,
    'height': height,
    'hdr': hdr == null ? null : _hdrWire(hdr!),
    'serverDecision': _methodWire(serverDecision),
    'transcodeReasons': transcodeReasons.map(_reasonWire).toList(),
  };
}

final class CorePlaybackReceiverEvidence {
  const CorePlaybackReceiverEvidence({
    required this.state,
    required this.videoCodecs,
    required this.audioCodecs,
    required this.subtitleFormats,
    required this.maxWidth,
    required this.maxHeight,
    required this.hdrTypes,
  });

  const CorePlaybackReceiverEvidence.unknown()
    : state = CorePlaybackEvidenceState.unknown,
      videoCodecs = const [],
      audioCodecs = const [],
      subtitleFormats = const [],
      maxWidth = null,
      maxHeight = null,
      hdrTypes = const [];

  final CorePlaybackEvidenceState state;
  final List<String> videoCodecs;
  final List<String> audioCodecs;
  final List<String> subtitleFormats;
  final int? maxWidth;
  final int? maxHeight;
  final List<CorePlaybackHdr> hdrTypes;

  Map<String, Object?> toJson() => {
    'state': state.name,
    'videoCodecs': videoCodecs,
    'audioCodecs': audioCodecs,
    'subtitleFormats': subtitleFormats,
    'maxWidth': maxWidth,
    'maxHeight': maxHeight,
    'hdrTypes': hdrTypes.map(_hdrWire).toList(),
  };
}

final class CorePlaybackNetworkEvidence {
  const CorePlaybackNetworkEvidence({
    required this.state,
    required this.transport,
    required this.downstreamKbps,
    required this.metered,
  });

  const CorePlaybackNetworkEvidence.unknown()
    : state = CorePlaybackEvidenceState.unknown,
      transport = null,
      downstreamKbps = null,
      metered = null;

  final CorePlaybackEvidenceState state;
  final CorePlaybackTransport? transport;

  /// Link estimate reported by the platform; never measured throughput.
  final int? downstreamKbps;
  final bool? metered;

  Map<String, Object?> toJson() => {
    'state': state.name,
    'transport': transport?.name,
    'downstreamKbps': downstreamKbps,
    'metered': metered,
  };
}

final class CorePlaybackQualityRequest {
  const CorePlaybackQualityRequest({
    required this.media,
    required this.receiver,
    required this.network,
  });

  final CorePlaybackMediaEvidence media;
  final CorePlaybackReceiverEvidence receiver;
  final CorePlaybackNetworkEvidence network;

  Map<String, Object?> toJson(String requestId) => {
    'schemaVersion': 1,
    'requestId': requestId,
    'media': media.toJson(),
    'receiver': receiver.toJson(),
    'network': network.toJson(),
  };
}

final class CorePlaybackRecommendation {
  const CorePlaybackRecommendation({
    required this.code,
    required this.maxBitrateBps,
    required this.processingLoad,
  });

  final CorePlaybackRecommendationCode code;
  final int? maxBitrateBps;
  final CorePlaybackProcessingLoad processingLoad;
}

final class CorePlaybackQualityAdvice {
  const CorePlaybackQualityAdvice({
    required this.requestId,
    required this.accountRevision,
    required this.method,
    required this.confidence,
    required this.codecEvidence,
    required this.bitrateEvidence,
    required this.networkEvidence,
    required this.receiverEvidence,
    required this.hdrEvidence,
    required this.gaps,
    required this.reasons,
    required this.recommendations,
  });

  factory CorePlaybackQualityAdvice.fromJson(
    Object? raw, {
    required ServerSession session,
    required String requestId,
  }) {
    final context = session.context;
    final family = session.sessionFamilyId;
    if (context == null || family == null) throw _invalid;
    final value = _object(raw, const {
      'schemaVersion',
      'authority',
      'requestId',
      'advisoryOnly',
      'physicalAcceptance',
      'method',
      'confidence',
      'evidence',
      'gaps',
      'reasons',
      'recommendations',
    });
    if (value['schemaVersion'] != 1 ||
        value['requestId'] != requestId ||
        value['advisoryOnly'] != true ||
        value['physicalAcceptance'] != 'manual') {
      throw _invalid;
    }
    final authority = _object(value['authority'], const {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'accountRevision',
      'sessionFamilyId',
    });
    if (authority['schemaVersion'] != 1 ||
        authority['coreId'] != context.coreId ||
        authority['homeId'] != context.homeId ||
        authority['accountId'] != session.user.id ||
        authority['sessionFamilyId'] != family) {
      throw _invalid;
    }
    final evidence = _object(value['evidence'], const {
      'schemaVersion',
      'codec',
      'bitrate',
      'network',
      'receiver',
      'hdr',
    });
    if (evidence['schemaVersion'] != 1) throw _invalid;
    final recommendations = _list(value['recommendations'], maximum: 7)
        .map((raw) {
          final item = _object(raw, const {
            'schemaVersion',
            'code',
            'maxBitrateBps',
            'processingLoad',
          });
          if (item['schemaVersion'] != 1) throw _invalid;
          final maximum = item['maxBitrateBps'];
          if (maximum != null &&
              (maximum is! int || maximum < 1 || maximum > 1000000000)) {
            throw _invalid;
          }
          return CorePlaybackRecommendation(
            code: _recommendation(item['code']),
            maxBitrateBps: maximum as int?,
            processingLoad: _processingLoad(item['processingLoad']),
          );
        })
        .toList(growable: false);
    return CorePlaybackQualityAdvice(
      requestId: requestId,
      accountRevision: _positiveInt(authority['accountRevision']),
      method: _method(value['method']),
      confidence: _state(value['confidence']),
      codecEvidence: _state(evidence['codec']),
      bitrateEvidence: _state(evidence['bitrate']),
      networkEvidence: _state(evidence['network']),
      receiverEvidence: _state(evidence['receiver']),
      hdrEvidence: _state(evidence['hdr']),
      gaps: _codes(value['gaps'], maximum: 6),
      reasons: _codes(value['reasons'], maximum: 12),
      recommendations: List.unmodifiable(recommendations),
    );
  }

  final String requestId;
  final int accountRevision;
  final CorePlaybackMethod method;
  final CorePlaybackEvidenceState confidence;
  final CorePlaybackEvidenceState codecEvidence;
  final CorePlaybackEvidenceState bitrateEvidence;
  final CorePlaybackEvidenceState networkEvidence;
  final CorePlaybackEvidenceState receiverEvidence;
  final CorePlaybackEvidenceState hdrEvidence;
  final List<String> gaps;
  final List<String> reasons;
  final List<CorePlaybackRecommendation> recommendations;
}

Map<String, dynamic> _object(Object? raw, Set<String> keys) {
  final value = serverObject(raw);
  if (value.length != keys.length || !value.keys.every(keys.contains)) {
    throw _invalid;
  }
  return value;
}

List<dynamic> _list(Object? raw, {required int maximum}) {
  if (raw is! List || raw.length > maximum) throw _invalid;
  return raw;
}

List<String> _codes(Object? raw, {required int maximum}) {
  final result = <String>[];
  for (final value in _list(raw, maximum: maximum)) {
    if (value is! String ||
        !RegExp(r'^[a-z0-9_]{1,64}$').hasMatch(value) ||
        result.contains(value)) {
      throw _invalid;
    }
    result.add(value);
  }
  return List.unmodifiable(result);
}

int _positiveInt(Object? value) {
  if (value is! int || value < 1 || value > 0x7fffffffffffffff) throw _invalid;
  return value;
}

CorePlaybackEvidenceState _state(Object? value) => switch (value) {
  'reported' => CorePlaybackEvidenceState.reported,
  'verified' => CorePlaybackEvidenceState.verified,
  'unknown' => CorePlaybackEvidenceState.unknown,
  _ => throw _invalid,
};

CorePlaybackMethod _method(Object? value) => switch (value) {
  'direct_play' => CorePlaybackMethod.directPlay,
  'remux' => CorePlaybackMethod.remux,
  'transcode' => CorePlaybackMethod.transcode,
  'unknown' => CorePlaybackMethod.unknown,
  _ => throw _invalid,
};

CorePlaybackRecommendationCode _recommendation(Object? value) =>
    switch (value) {
      'keep_original' => CorePlaybackRecommendationCode.keepOriginal,
      'lower_bitrate' => CorePlaybackRecommendationCode.lowerBitrate,
      'prefer_compatible_audio' =>
        CorePlaybackRecommendationCode.preferCompatibleAudio,
      'prefer_external_subtitle' =>
        CorePlaybackRecommendationCode.preferExternalSubtitle,
      'inspect_receiver' => CorePlaybackRecommendationCode.inspectReceiver,
      'measure_network' => CorePlaybackRecommendationCode.measureNetwork,
      'verify_hdr_on_device' =>
        CorePlaybackRecommendationCode.verifyHdrOnDevice,
      _ => throw _invalid,
    };

CorePlaybackProcessingLoad _processingLoad(Object? value) => switch (value) {
  'low' => CorePlaybackProcessingLoad.low,
  'medium' => CorePlaybackProcessingLoad.medium,
  'high' => CorePlaybackProcessingLoad.high,
  'unknown' => CorePlaybackProcessingLoad.unknown,
  _ => throw _invalid,
};

String _methodWire(CorePlaybackMethod value) => switch (value) {
  CorePlaybackMethod.directPlay => 'direct_play',
  CorePlaybackMethod.remux => 'remux',
  CorePlaybackMethod.transcode => 'transcode',
  CorePlaybackMethod.unknown => 'unknown',
};

String _hdrWire(CorePlaybackHdr value) => switch (value) {
  CorePlaybackHdr.sdr => 'sdr',
  CorePlaybackHdr.hdr10 => 'hdr10',
  CorePlaybackHdr.hdr10Plus => 'hdr10_plus',
  CorePlaybackHdr.dolbyVision => 'dolby_vision',
  CorePlaybackHdr.hlg => 'hlg',
  CorePlaybackHdr.unknown => 'unknown',
};

String _reasonWire(CorePlaybackTranscodeReason value) => switch (value) {
  CorePlaybackTranscodeReason.container => 'container',
  CorePlaybackTranscodeReason.videoCodec => 'video_codec',
  CorePlaybackTranscodeReason.audioCodec => 'audio_codec',
  CorePlaybackTranscodeReason.subtitle => 'subtitle',
  CorePlaybackTranscodeReason.bitrate => 'bitrate',
  CorePlaybackTranscodeReason.resolution => 'resolution',
  CorePlaybackTranscodeReason.hdr => 'hdr',
  CorePlaybackTranscodeReason.network => 'network',
  CorePlaybackTranscodeReason.receiver => 'receiver',
  CorePlaybackTranscodeReason.unknown => 'unknown',
};

const _invalid = LarenorServerException('invalid_response');
