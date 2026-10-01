import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/core_catalog_player_binding.dart';

const _channelName = 'com.ersingundem.larenor/playback-quality';
const _method = 'localPlaybackProfileSnapshot';
const _maxSafeInteger = 9007199254740991;
const _profileKind = 'larenor.android.core-local-player.v1';
const _defaultBitrateBps = 20000000;
const _defaultContainers = <String>['mp4'];

final class CoreCatalogLocalPlaybackProfile {
  CoreCatalogLocalPlaybackProfile._({
    required this.profileId,
    required this.profileRevision,
    required this.displayRevision,
    required this.decoderRevision,
    required this.networkRevision,
    required this.policyRevision,
    required this.containers,
    required this.videoCodecs,
    required this.audioCodecs,
    required this.subtitleFormats,
    required this.maxWidth,
    required this.maxHeight,
    required this.maxStreamingBitrateBps,
  });

  final String profileId;
  final int profileRevision;
  final int displayRevision;
  final int decoderRevision;
  final int networkRevision;
  final int policyRevision;
  final List<String> containers;
  final List<String> videoCodecs;
  final List<String> audioCodecs;
  final List<String> subtitleFormats;
  final int maxWidth;
  final int maxHeight;
  final int maxStreamingBitrateBps;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'evidence': 'client_reported',
    'profileId': profileId,
    'profileRevision': profileRevision,
    'displayRevision': displayRevision,
    'decoderRevision': decoderRevision,
    'networkRevision': networkRevision,
    'policyRevision': policyRevision,
    'containers': containers,
    'videoCodecs': videoCodecs,
    'audioCodecs': audioCodecs,
    'subtitleFormats': subtitleFormats,
    'maxWidth': maxWidth,
    'maxHeight': maxHeight,
    'maxStreamingBitrateBps': maxStreamingBitrateBps,
  };

  String get digest =>
      sha256.convert(utf8.encode(_canonical(toJson()))).toString();

  bool sameFacts(CoreCatalogLocalPlaybackProfile other) =>
      digest == other.digest;
}

final class CoreCatalogPlaybackAuthorization {
  const CoreCatalogPlaybackAuthorization._({
    required this.observationId,
    required this.profile,
    required this.expiresAt,
    required this._accountGeneration,
    required this._session,
  });

  final String observationId;
  final CoreCatalogLocalPlaybackProfile profile;
  final DateTime expiresAt;
  final int _accountGeneration;
  final ServerSession _session;
}

enum CoreCatalogPlaybackOutcome {
  directPlaySupported,
  requiresRemux,
  requiresTranscode,
  unavailable,
  contractUnknown,
}

enum CoreCatalogPlaybackMethod { unknown, directPlay, directStream, transcode }

enum CoreCatalogPlaybackReason {
  available,
  multipleSources,
  originalByteMismatch,
  noSupportedMethod,
  contractUnsupported,
}

final class CoreCatalogPlaybackSourceEvidence {
  const CoreCatalogPlaybackSourceEvidence._({
    required this.container,
    required this.bitrateBps,
    required this.videoCodecs,
    required this.audioCodecs,
    required this.videoRanges,
  });

  final String? container;
  final int? bitrateBps;
  final List<String> videoCodecs, audioCodecs, videoRanges;
}

final class CoreCatalogPlaybackTranscodingEvidence {
  const CoreCatalogPlaybackTranscodingEvidence._({
    required this.container,
    required this.videoCodec,
    required this.audioCodec,
    required this.bitrateBps,
    required this.reasons,
  });

  final String? container, videoCodec, audioCodec;
  final int? bitrateBps;
  final List<String> reasons;
}

/// A short-lived provider observation bound to the exact current native
/// profile and Core authority. It is advice only and does not create or
/// consume a playback lease.
final class CoreCatalogPlaybackAssessment {
  const CoreCatalogPlaybackAssessment._({
    required this.profile,
    required this.outcome,
    required this.method,
    required this.source,
    required this.transcoding,
    required this.reason,
    required this.observedAt,
    required this.expiresAt,
    required this._observationId,
    required this._accountGeneration,
    required this._session,
  });

  final CoreCatalogLocalPlaybackProfile profile;
  final CoreCatalogPlaybackOutcome outcome;
  final CoreCatalogPlaybackMethod method;
  final CoreCatalogPlaybackSourceEvidence? source;
  final CoreCatalogPlaybackTranscodingEvidence? transcoding;
  final CoreCatalogPlaybackReason reason;
  final DateTime observedAt, expiresAt;
  final String? _observationId;
  final int _accountGeneration;
  final ServerSession _session;

  bool get allowsOriginalBytes =>
      outcome == CoreCatalogPlaybackOutcome.directPlaySupported &&
      method == CoreCatalogPlaybackMethod.directPlay;
}

abstract interface class CoreCatalogPlaybackCapabilityPort {
  Future<Object?> snapshot();
}

final class MethodChannelCoreCatalogPlaybackCapabilityPort
    implements CoreCatalogPlaybackCapabilityPort {
  MethodChannelCoreCatalogPlaybackCapabilityPort({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  final MethodChannel _channel;

  @override
  Future<Object?> snapshot() => _channel.invokeMethod<Object?>(_method);
}

/// Converts current Android facts into one bounded, explicitly
/// client-reported profile and binds one provider observation to it.
///
/// Decoder MIME presence does not claim a profile, level, hardware path or
/// successful playback. The provider's short-lived direct-play observation is
/// still required before F27 may issue an original-byte lease.
final class CoreCatalogPlaybackCapabilityAdapter {
  CoreCatalogPlaybackCapabilityAdapter(
    this._account, {
    CoreCatalogPlaybackCapabilityPort? port,
    int maxStreamingBitrateBps = _defaultBitrateBps,
    List<String> containers = _defaultContainers,
    String Function()? requestId,
    DateTime Function()? clock,
  }) : _port = port ?? MethodChannelCoreCatalogPlaybackCapabilityPort(),
       _maxStreamingBitrateBps = maxStreamingBitrateBps,
       _containers = List.unmodifiable([...containers]..sort()),
       _requestId = requestId ?? _randomId,
       _clock = clock ?? (() => DateTime.now().toUtc()) {
    if (!_rate(maxStreamingBitrateBps) ||
        containers.isEmpty ||
        containers.length > 16 ||
        containers.toSet().length != containers.length ||
        _containers.any((value) => !_token.hasMatch(value))) {
      throw ArgumentError('Invalid local playback policy');
    }
  }

  final ServerAccountController _account;
  final CoreCatalogPlaybackCapabilityPort _port;
  final int _maxStreamingBitrateBps;
  final List<String> _containers;
  final String Function() _requestId;
  final DateTime Function() _clock;

  void addAuthorityListener(VoidCallback listener) =>
      _account.addListener(listener);

  void removeAuthorityListener(VoidCallback listener) =>
      _account.removeListener(listener);

  Duration remaining(CoreCatalogPlaybackAssessment assessment) =>
      assessment.expiresAt.difference(_clock());

  Future<CoreCatalogLocalPlaybackProfile?> capture() async {
    try {
      return _profile(
        _NativeLocalPlaybackFacts.fromChannel(await _port.snapshot()),
      );
    } catch (_) {
      return null;
    }
  }

  Future<CoreCatalogPlaybackAuthorization?> observe(
    CoreCatalogPlayerBinding binding, {
    required bool Function() current,
  }) async {
    final assessment = await _assess(binding, current: current, recorded: true);
    if (assessment == null ||
        !assessment.allowsOriginalBytes ||
        assessment._observationId == null) {
      return null;
    }
    return CoreCatalogPlaybackAuthorization._(
      observationId: assessment._observationId,
      profile: assessment.profile,
      expiresAt: assessment.expiresAt,
      accountGeneration: assessment._accountGeneration,
      session: assessment._session,
    );
  }

  Future<CoreCatalogPlaybackAssessment?> assess(
    CoreCatalogPlayerBinding binding, {
    required bool Function() current,
  }) => _assess(binding, current: current, recorded: false);

  Future<CoreCatalogPlaybackAssessment?> _assess(
    CoreCatalogPlayerBinding binding, {
    required bool Function() current,
    required bool recorded,
  }) async {
    final accountGeneration = _account.generation;
    final capturedSession = _account.session;
    if (capturedSession == null || !current()) return null;
    final profile = await capture();
    if (profile == null ||
        !current() ||
        !_account.isCurrent(accountGeneration)) {
      return null;
    }
    final requestId = _requestId();
    if (!_identity.hasMatch(requestId)) return null;
    try {
      return await _account.withSession((api, session) async {
        if (!identical(session, capturedSession) ||
            !current() ||
            !_account.isCurrent(accountGeneration)) {
          throw const LarenorServerException('cancelled');
        }
        final context = session.context;
        if (context == null || session.sessionFamilyId == null) {
          throw const LarenorServerException('invalid_session');
        }
        final response = await api.request(
          'POST',
          '/media/playback-quality/${context.coreId}/${context.homeId}/'
              '${recorded ? 'observe-item' : 'assess-item'}',
          token: session.accessToken,
          body: {
            'schemaVersion': 1,
            'requestId': requestId,
            'installationId': binding.installationId,
            'expectedInstallationRevision': binding.installationRevision,
            'expectedSnapshotRevision': binding.snapshotRevision,
            'expectedJellyfinServiceRevision': binding.jellyfinServiceRevision,
            'itemId': binding.itemId,
            'mediaKey': binding.mediaKey,
            'localProfile': profile.toJson(),
          },
        );
        final assessment = _assessment(
          response,
          binding: binding,
          profile: profile,
          requestId: requestId,
          session: session,
          accountGeneration: accountGeneration,
          recorded: recorded,
        );
        if (assessment == null ||
            !current() ||
            !_account.isCurrent(accountGeneration)) {
          return null;
        }
        final after = await capture();
        if (after == null ||
            !profile.sameFacts(after) ||
            !current() ||
            !_account.isCurrent(accountGeneration) ||
            !identical(_account.session, capturedSession) ||
            !assessment.expiresAt.isAfter(_clock())) {
          return null;
        }
        return assessment;
      });
    } catch (_) {
      return null;
    }
  }

  Future<bool> revalidate(
    CoreCatalogPlaybackAuthorization authorization, {
    required bool Function() current,
  }) async {
    if (!current() ||
        !_account.isCurrent(authorization._accountGeneration) ||
        !identical(_account.session, authorization._session) ||
        !authorization.expiresAt.isAfter(_clock())) {
      return false;
    }
    final after = await capture();
    return current() &&
        _account.isCurrent(authorization._accountGeneration) &&
        identical(_account.session, authorization._session) &&
        after != null &&
        authorization.profile.sameFacts(after) &&
        authorization.expiresAt.isAfter(_clock());
  }

  Future<bool> revalidateAssessment(
    CoreCatalogPlaybackAssessment assessment, {
    required bool Function() current,
  }) async {
    if (!current() ||
        !_account.isCurrent(assessment._accountGeneration) ||
        !identical(_account.session, assessment._session) ||
        !assessment.expiresAt.isAfter(_clock())) {
      return false;
    }
    final after = await capture();
    return current() &&
        _account.isCurrent(assessment._accountGeneration) &&
        identical(_account.session, assessment._session) &&
        after != null &&
        assessment.profile.sameFacts(after) &&
        assessment.expiresAt.isAfter(_clock());
  }

  CoreCatalogLocalPlaybackProfile? _profile(_NativeLocalPlaybackFacts facts) {
    if (facts.decoderMimeTypesTruncated ||
        facts.displayWidthPixels < 320 ||
        facts.displayWidthPixels > 8192 ||
        facts.displayHeightPixels < 320 ||
        facts.displayHeightPixels > 8192) {
      return null;
    }
    final video = <String>{};
    final audio = <String>{};
    for (final mime in facts.decoderMimeTypes) {
      final codec = _codecByMime[mime];
      if (codec == null) continue;
      (mime.startsWith('video/') ? video : audio).add(codec);
    }
    final videoCodecs = video.toList()..sort();
    final audioCodecs = audio.toList()..sort();
    if (videoCodecs.isEmpty || audioCodecs.isEmpty) return null;
    final profileId = sha256
        .convert(utf8.encode(_profileKind))
        .toString()
        .substring(0, 32);
    final policyRevision = _revision({
      'kind': _profileKind,
      'containers': _containers,
      'subtitleFormats': const <String>[],
      'maxStreamingBitrateBps': _maxStreamingBitrateBps,
    });
    final profileRevision = _revision({
      'profileId': profileId,
      'displayRevision': facts.displayRevision,
      'decoderRevision': facts.decoderRevision,
      'networkRevision': facts.networkRevision,
      'policyRevision': policyRevision,
    });
    return CoreCatalogLocalPlaybackProfile._(
      profileId: profileId,
      profileRevision: profileRevision,
      displayRevision: facts.displayRevision,
      decoderRevision: facts.decoderRevision,
      networkRevision: facts.networkRevision,
      policyRevision: policyRevision,
      containers: _containers,
      videoCodecs: List.unmodifiable(videoCodecs),
      audioCodecs: List.unmodifiable(audioCodecs),
      subtitleFormats: const [],
      maxWidth: facts.displayWidthPixels,
      maxHeight: facts.displayHeightPixels,
      maxStreamingBitrateBps: _maxStreamingBitrateBps,
    );
  }

  CoreCatalogPlaybackAssessment? _assessment(
    Object? raw, {
    required CoreCatalogPlayerBinding binding,
    required CoreCatalogLocalPlaybackProfile profile,
    required String requestId,
    required ServerSession session,
    required int accountGeneration,
    required bool recorded,
  }) {
    final value = _closedMap(raw, {
      'schemaVersion',
      'requestId',
      if (recorded) 'observationId',
      'authority',
      'observation',
    });
    final authority = _closedMap(value['authority'], const {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'accountRevision',
      'sessionFamilyId',
      'installationId',
      'installationRevision',
      'snapshotRevision',
      'jellyfinServiceRevision',
      'itemId',
      'mediaKey',
      'profileId',
      'profileRevision',
      'displayRevision',
      'decoderRevision',
      'networkRevision',
      'policyRevision',
      'profileDigest',
    });
    final observation = _closedMap(value['observation'], const {
      'schemaVersion',
      'assurance',
      'originalByteOutcome',
      'playMethod',
      'source',
      'transcoding',
      'reason',
      'advisoryOnly',
      'physicalAcceptance',
      'observedAt',
      'expiresAt',
    });
    final context = session.context;
    final observedAt = _timestamp(observation['observedAt']);
    final expiresAt = _timestamp(observation['expiresAt']);
    final outcome = switch (observation['originalByteOutcome']) {
      'direct_play_supported' => CoreCatalogPlaybackOutcome.directPlaySupported,
      'requires_remux' => CoreCatalogPlaybackOutcome.requiresRemux,
      'requires_transcode' => CoreCatalogPlaybackOutcome.requiresTranscode,
      'unavailable' => CoreCatalogPlaybackOutcome.unavailable,
      'contract_unknown' => CoreCatalogPlaybackOutcome.contractUnknown,
      _ => null,
    };
    final method = switch (observation['playMethod']) {
      'unknown' => CoreCatalogPlaybackMethod.unknown,
      'direct_play' => CoreCatalogPlaybackMethod.directPlay,
      'direct_stream' => CoreCatalogPlaybackMethod.directStream,
      'transcode' => CoreCatalogPlaybackMethod.transcode,
      _ => null,
    };
    final reason = switch (observation['reason']) {
      'available' => CoreCatalogPlaybackReason.available,
      'multiple_sources' => CoreCatalogPlaybackReason.multipleSources,
      'original_byte_mismatch' =>
        CoreCatalogPlaybackReason.originalByteMismatch,
      'no_supported_method' => CoreCatalogPlaybackReason.noSupportedMethod,
      'contract_unsupported' => CoreCatalogPlaybackReason.contractUnsupported,
      _ => null,
    };
    final source = _source(observation['source']);
    final transcoding = _transcoding(observation['transcoding']);
    final expiration = DateTime.fromMillisecondsSinceEpoch(
      expiresAt * 1000,
      isUtc: true,
    );
    final observationTime = DateTime.fromMillisecondsSinceEpoch(
      observedAt * 1000,
      isUtc: true,
    );
    if (value['schemaVersion'] != 1 ||
        value['requestId'] != requestId ||
        (recorded &&
            (value['observationId'] is! String ||
                !_identity.hasMatch(value['observationId'] as String))) ||
        context == null ||
        authority['schemaVersion'] != 1 ||
        authority['coreId'] != context.coreId ||
        authority['homeId'] != context.homeId ||
        authority['accountId'] != session.user.id ||
        authority['sessionFamilyId'] != session.sessionFamilyId ||
        authority['installationId'] != binding.installationId ||
        authority['installationRevision'] != binding.installationRevision ||
        authority['snapshotRevision'] != binding.snapshotRevision ||
        authority['jellyfinServiceRevision'] !=
            binding.jellyfinServiceRevision ||
        authority['itemId'] != binding.itemId ||
        authority['mediaKey'] != binding.mediaKey ||
        authority['profileId'] != profile.profileId ||
        authority['profileRevision'] != profile.profileRevision ||
        authority['displayRevision'] != profile.displayRevision ||
        authority['decoderRevision'] != profile.decoderRevision ||
        authority['networkRevision'] != profile.networkRevision ||
        authority['policyRevision'] != profile.policyRevision ||
        authority['profileDigest'] != profile.digest ||
        !_safeRevision(authority['accountRevision']) ||
        observation['schemaVersion'] != 1 ||
        observation['assurance'] !=
            'provider_observed_for_client_reported_profile' ||
        outcome == null ||
        method == null ||
        reason == null ||
        !_coherent(outcome, method, reason, source, transcoding) ||
        observation['advisoryOnly'] != true ||
        observation['physicalAcceptance'] != 'manual' ||
        observedAt >= expiresAt ||
        expiresAt > observedAt + 30 ||
        observationTime.isAfter(_clock()) ||
        !expiration.isAfter(_clock())) {
      return null;
    }
    return CoreCatalogPlaybackAssessment._(
      profile: profile,
      outcome: outcome,
      method: method,
      source: source,
      transcoding: transcoding,
      reason: reason,
      observedAt: observationTime,
      expiresAt: expiration,
      observationId: recorded ? value['observationId'] as String : null,
      accountGeneration: accountGeneration,
      session: session,
    );
  }

  CoreCatalogPlaybackSourceEvidence? _source(Object? raw) {
    if (raw == null) return null;
    final value = _closedMap(raw, const {
      'container',
      'bitrateBps',
      'videoCodecs',
      'audioCodecs',
      'videoRanges',
    });
    final container = _nullableToken(value['container']);
    final bitrate = _nullableRate(value['bitrateBps']);
    return CoreCatalogPlaybackSourceEvidence._(
      container: container,
      bitrateBps: bitrate,
      videoCodecs: _tokens(value['videoCodecs'], 8, _token),
      audioCodecs: _tokens(value['audioCodecs'], 8, _token),
      videoRanges: _tokens(value['videoRanges'], 8, _token),
    );
  }

  CoreCatalogPlaybackTranscodingEvidence? _transcoding(Object? raw) {
    if (raw == null) return null;
    final value = _closedMap(raw, const {
      'container',
      'videoCodec',
      'audioCodec',
      'bitrateBps',
      'reasons',
    });
    return CoreCatalogPlaybackTranscodingEvidence._(
      container: _nullableToken(value['container']),
      videoCodec: _nullableToken(value['videoCodec']),
      audioCodec: _nullableToken(value['audioCodec']),
      bitrateBps: _nullableRate(value['bitrateBps']),
      reasons: _uniqueTokens(value['reasons'], 16, _token),
    );
  }
}

final class _NativeLocalPlaybackFacts {
  const _NativeLocalPlaybackFacts({
    required this.displayWidthPixels,
    required this.displayHeightPixels,
    required this.displayRevision,
    required this.decoderMimeTypes,
    required this.decoderMimeTypesTruncated,
    required this.decoderRevision,
    required this.networkRevision,
  });

  factory _NativeLocalPlaybackFacts.fromChannel(Object? raw) {
    final value = _closedMap(raw, const {
      'schemaVersion',
      'displayWidthPixels',
      'displayHeightPixels',
      'displayRevision',
      'decoderMimeTypes',
      'decoderMimeTypesTruncated',
      'decoderRevision',
      'networkTransports',
      'networkValidated',
      'networkMetered',
      'networkDownstreamKbps',
      'networkRevision',
    });
    final mimeTypes = _tokens(value['decoderMimeTypes'], 128, _mimeType);
    _tokens(value['networkTransports'], 12, _networkTransport);
    if (value['schemaVersion'] != 1 ||
        value['decoderMimeTypesTruncated'] is! bool ||
        value['networkValidated'] is! bool ||
        value['networkMetered'] is! bool ||
        (value['networkDownstreamKbps'] != null &&
            !_boundedInteger(value['networkDownstreamKbps'], 10000000))) {
      throw const FormatException('Invalid native playback facts');
    }
    return _NativeLocalPlaybackFacts(
      displayWidthPixels: _integer(value['displayWidthPixels'], 16384),
      displayHeightPixels: _integer(value['displayHeightPixels'], 16384),
      displayRevision: _revisionValue(value['displayRevision']),
      decoderMimeTypes: mimeTypes,
      decoderMimeTypesTruncated: value['decoderMimeTypesTruncated'] as bool,
      decoderRevision: _revisionValue(value['decoderRevision']),
      networkRevision: _revisionValue(value['networkRevision']),
    );
  }

  final int displayWidthPixels;
  final int displayHeightPixels;
  final int displayRevision;
  final List<String> decoderMimeTypes;
  final bool decoderMimeTypesTruncated;
  final int decoderRevision;
  final int networkRevision;
}

Map<Object?, Object?> _closedMap(Object? raw, Set<String> keys) {
  if (raw is! Map<Object?, Object?> ||
      raw.length != keys.length ||
      raw.keys.any((key) => key is! String || !keys.contains(key))) {
    throw const FormatException('Invalid playback capability response');
  }
  return raw;
}

List<String> _tokens(Object? raw, int maximum, RegExp pattern) {
  final result = _uniqueTokens(raw, maximum, pattern);
  final sorted = [...result]..sort();
  if (!_same(result, sorted)) {
    throw const FormatException('Unstable playback capability ordering');
  }
  return result;
}

List<String> _uniqueTokens(Object? raw, int maximum, RegExp pattern) {
  if (raw is! List<Object?> || raw.length > maximum) {
    throw const FormatException('Invalid playback capability list');
  }
  final result = <String>[];
  for (final item in raw) {
    if (item is! String || !pattern.hasMatch(item) || result.contains(item)) {
      throw const FormatException('Invalid playback capability token');
    }
    result.add(item);
  }
  return List.unmodifiable(result);
}

int _integer(Object? raw, int maximum) {
  if (!_boundedInteger(raw, maximum)) {
    throw const FormatException('Invalid playback capability integer');
  }
  return raw as int;
}

int _revisionValue(Object? raw) {
  if (!_safeRevision(raw)) {
    throw const FormatException('Invalid playback capability revision');
  }
  return raw as int;
}

int _timestamp(Object? raw) {
  if (raw is! int || raw < 1 || raw > 253402300799) {
    throw const FormatException('Invalid playback observation time');
  }
  return raw;
}

String? _nullableToken(Object? raw) {
  if (raw == null) return null;
  if (raw is! String || !_token.hasMatch(raw)) {
    throw const FormatException('Invalid playback capability token');
  }
  return raw;
}

int? _nullableRate(Object? raw) {
  if (raw == null) return null;
  if (!_boundedInteger(raw, 1000000000)) {
    throw const FormatException('Invalid playback capability rate');
  }
  return raw as int;
}

bool _coherent(
  CoreCatalogPlaybackOutcome outcome,
  CoreCatalogPlaybackMethod method,
  CoreCatalogPlaybackReason reason,
  CoreCatalogPlaybackSourceEvidence? source,
  CoreCatalogPlaybackTranscodingEvidence? transcoding,
) => switch (outcome) {
  CoreCatalogPlaybackOutcome.directPlaySupported =>
    method == CoreCatalogPlaybackMethod.directPlay &&
        reason == CoreCatalogPlaybackReason.available &&
        source != null &&
        transcoding == null,
  CoreCatalogPlaybackOutcome.requiresRemux =>
    method == CoreCatalogPlaybackMethod.directStream &&
        reason == CoreCatalogPlaybackReason.available &&
        source != null &&
        transcoding == null,
  CoreCatalogPlaybackOutcome.requiresTranscode =>
    method == CoreCatalogPlaybackMethod.transcode &&
        reason == CoreCatalogPlaybackReason.available &&
        source != null &&
        transcoding != null,
  CoreCatalogPlaybackOutcome.unavailable =>
    method == CoreCatalogPlaybackMethod.unknown &&
        reason == CoreCatalogPlaybackReason.noSupportedMethod &&
        source == null &&
        transcoding == null,
  CoreCatalogPlaybackOutcome.contractUnknown =>
    method == CoreCatalogPlaybackMethod.unknown &&
        const {
          CoreCatalogPlaybackReason.multipleSources,
          CoreCatalogPlaybackReason.originalByteMismatch,
          CoreCatalogPlaybackReason.contractUnsupported,
        }.contains(reason) &&
        source == null &&
        transcoding == null,
};

bool _boundedInteger(Object? raw, int maximum) =>
    raw is int && raw >= 1 && raw <= maximum;
bool _safeRevision(Object? raw) => _boundedInteger(raw, _maxSafeInteger);
bool _rate(int value) => value >= 1 && value <= 1000000000;

int _revision(Object? value) {
  final bytes = sha256.convert(utf8.encode(_canonical(value))).bytes;
  var result = 0;
  for (var index = 0; index < 7; index++) {
    result = (result << 8) | bytes[index];
  }
  result &= _maxSafeInteger;
  return result == 0 ? 1 : result;
}

String _canonical(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonical(value[key])}').join(',')}}';
  }
  if (value is List<Object?>) {
    return '[${value.map(_canonical).join(',')}]';
  }
  return jsonEncode(value);
}

bool _same(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String _randomId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

const _codecByMime = <String, String>{
  'video/avc': 'h264',
  'video/hevc': 'hevc',
  'video/av01': 'av1',
  'video/x-vnd.on2.vp8': 'vp8',
  'video/x-vnd.on2.vp9': 'vp9',
  'audio/mp4a-latm': 'aac',
  'audio/ac3': 'ac3',
  'audio/eac3': 'eac3',
  'audio/eac3-joc': 'eac3',
  'audio/opus': 'opus',
  'audio/vorbis': 'vorbis',
  'audio/flac': 'flac',
};

final _identity = RegExp(r'^[0-9a-f]{32}$');
final _token = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._,+-]{0,63}$');
final _mimeType = RegExp(
  r'^[a-z0-9][a-z0-9!#&^_.+-]{0,63}/[a-z0-9][a-z0-9!#&^_.+-]{0,127}$',
);
final _networkTransport = RegExp(
  r'^(bluetooth|cellular|ethernet|lowpan|satellite|thread|usb|vpn|wifi|wifiAware)$',
);
