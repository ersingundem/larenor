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
          '/media/playback-quality/${context.coreId}/${context.homeId}/observe-item',
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
        final authorization = _authorization(
          response,
          binding: binding,
          profile: profile,
          requestId: requestId,
          session: session,
          accountGeneration: accountGeneration,
        );
        if (authorization == null ||
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
            !authorization.expiresAt.isAfter(_clock())) {
          return null;
        }
        return authorization;
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

  CoreCatalogPlaybackAuthorization? _authorization(
    Object? raw, {
    required CoreCatalogPlayerBinding binding,
    required CoreCatalogLocalPlaybackProfile profile,
    required String requestId,
    required ServerSession session,
    required int accountGeneration,
  }) {
    final value = _closedMap(raw, const {
      'schemaVersion',
      'requestId',
      'observationId',
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
    final source = _closedMap(observation['source'], const {
      'container',
      'bitrateBps',
      'videoCodecs',
      'audioCodecs',
      'videoRanges',
    });
    final sourceContainer = source['container'];
    final sourceBitrate = source['bitrateBps'];
    _tokens(source['videoCodecs'], 8, _token);
    _tokens(source['audioCodecs'], 8, _token);
    _tokens(source['videoRanges'], 8, _token);
    final context = session.context;
    final observedAt = _timestamp(observation['observedAt']);
    final expiresAt = _timestamp(observation['expiresAt']);
    final expiration = DateTime.fromMillisecondsSinceEpoch(
      expiresAt * 1000,
      isUtc: true,
    );
    if (value['schemaVersion'] != 1 ||
        value['requestId'] != requestId ||
        value['observationId'] is! String ||
        !_identity.hasMatch(value['observationId'] as String) ||
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
        observation['originalByteOutcome'] != 'direct_play_supported' ||
        observation['playMethod'] != 'direct_play' ||
        (sourceContainer != null &&
            (sourceContainer is! String ||
                !_token.hasMatch(sourceContainer))) ||
        (sourceBitrate != null &&
            !_boundedInteger(sourceBitrate, 1000000000)) ||
        observation['transcoding'] != null ||
        observation['reason'] != 'available' ||
        observation['advisoryOnly'] != true ||
        observation['physicalAcceptance'] != 'manual' ||
        observedAt >= expiresAt ||
        expiresAt > observedAt + 30 ||
        !expiration.isAfter(_clock())) {
      return null;
    }
    return CoreCatalogPlaybackAuthorization._(
      observationId: value['observationId'] as String,
      profile: profile,
      expiresAt: expiration,
      accountGeneration: accountGeneration,
      session: session,
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
  final sorted = [...result]..sort();
  if (!_same(result, sorted)) {
    throw const FormatException('Unstable playback capability ordering');
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
