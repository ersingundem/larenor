import 'package:flutter/services.dart';

const _channelName = 'com.ersingundem.larenor/playback-quality';
const _schemaVersion = 1;
const _maxDecoderMimeTypes = 128;
const _maxDisplayPixels = 16384;
const _maxHdrTypes = 8;
const _maxNetworkTransports = 12;
const _maxDownstreamKbps = 10000000;

final class AndroidPlaybackCapabilitySnapshot {
  const AndroidPlaybackCapabilitySnapshot({
    required this.decoderMimeTypes,
    required this.decoderMimeTypesTruncated,
    required this.displayWidthPixels,
    required this.displayHeightPixels,
    required this.displayHdrTypes,
    required this.networkTransports,
    required this.networkValidated,
    required this.networkMetered,
    required this.networkDownstreamKbps,
  });

  factory AndroidPlaybackCapabilitySnapshot.fromChannel(Object? raw) {
    final value = _closedMap(raw, const {
      'schemaVersion',
      'decoderMimeTypes',
      'decoderMimeTypesTruncated',
      'displayWidthPixels',
      'displayHeightPixels',
      'displayHdrTypes',
      'networkTransports',
      'networkValidated',
      'networkMetered',
      'networkDownstreamKbps',
    });
    if (value['schemaVersion'] != _schemaVersion) {
      throw const FormatException('Unsupported playback capability schema');
    }

    final decoderMimeTypes = _nullableTokens(
      value['decoderMimeTypes'],
      maximumCount: _maxDecoderMimeTypes,
      allowed: _mimeType,
    );
    final decoderMimeTypesTruncated = _boolean(
      value['decoderMimeTypesTruncated'],
    );
    if ((decoderMimeTypes == null && decoderMimeTypesTruncated) ||
        (decoderMimeTypesTruncated &&
            decoderMimeTypes!.length != _maxDecoderMimeTypes)) {
      throw const FormatException('Invalid decoder capability evidence');
    }

    final displayWidthPixels = _nullableInteger(
      value['displayWidthPixels'],
      maximum: _maxDisplayPixels,
    );
    final displayHeightPixels = _nullableInteger(
      value['displayHeightPixels'],
      maximum: _maxDisplayPixels,
    );
    if ((displayWidthPixels == null) != (displayHeightPixels == null)) {
      throw const FormatException('Invalid display resolution evidence');
    }
    final displayHdrTypes = _nullableTokens(
      value['displayHdrTypes'],
      maximumCount: _maxHdrTypes,
      allowed: _hdrType,
    );

    final networkTransports = _nullableTokens(
      value['networkTransports'],
      maximumCount: _maxNetworkTransports,
      allowed: _networkTransport,
    );
    final networkValidated = _nullableBoolean(value['networkValidated']);
    final networkMetered = _nullableBoolean(value['networkMetered']);
    final networkDownstreamKbps = _nullableInteger(
      value['networkDownstreamKbps'],
      maximum: _maxDownstreamKbps,
    );
    if (networkTransports == null &&
        (networkValidated != null ||
            networkMetered != null ||
            networkDownstreamKbps != null)) {
      throw const FormatException('Invalid network capability evidence');
    }

    return AndroidPlaybackCapabilitySnapshot(
      decoderMimeTypes: decoderMimeTypes,
      decoderMimeTypesTruncated: decoderMimeTypesTruncated,
      displayWidthPixels: displayWidthPixels,
      displayHeightPixels: displayHeightPixels,
      displayHdrTypes: displayHdrTypes,
      networkTransports: networkTransports,
      networkValidated: networkValidated,
      networkMetered: networkMetered,
      networkDownstreamKbps: networkDownstreamKbps,
    );
  }

  final List<String>? decoderMimeTypes;
  final bool decoderMimeTypesTruncated;
  final int? displayWidthPixels;
  final int? displayHeightPixels;
  final List<String>? displayHdrTypes;
  final List<String>? networkTransports;
  final bool? networkValidated;
  final bool? networkMetered;

  /// Android's bounded link-capability estimate. This is not measured
  /// throughput and must not be presented as a network quality guarantee.
  final int? networkDownstreamKbps;
}

abstract interface class AndroidPlaybackCapabilityPort {
  Future<AndroidPlaybackCapabilitySnapshot> snapshot();
}

final class MethodChannelAndroidPlaybackCapabilityPort
    implements AndroidPlaybackCapabilityPort {
  MethodChannelAndroidPlaybackCapabilityPort({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  final MethodChannel _channel;

  @override
  Future<AndroidPlaybackCapabilitySnapshot> snapshot() async {
    final raw = await _channel.invokeMethod<Object?>('snapshot');
    return AndroidPlaybackCapabilitySnapshot.fromChannel(raw);
  }
}

Map<Object?, Object?> _closedMap(Object? raw, Set<String> expectedKeys) {
  if (raw is! Map<Object?, Object?> ||
      raw.length != expectedKeys.length ||
      raw.keys.any((key) => key is! String || !expectedKeys.contains(key))) {
    throw const FormatException('Invalid playback capability response');
  }
  return raw;
}

List<String>? _nullableTokens(
  Object? raw, {
  required int maximumCount,
  required RegExp allowed,
}) {
  if (raw == null) return null;
  if (raw is! List<Object?> || raw.length > maximumCount) {
    throw const FormatException('Invalid playback capability list');
  }
  final values = <String>[];
  for (final item in raw) {
    if (item is! String || !allowed.hasMatch(item) || values.contains(item)) {
      throw const FormatException('Invalid playback capability token');
    }
    values.add(item);
  }
  final sorted = [...values]..sort();
  if (!_sameStrings(values, sorted)) {
    throw const FormatException('Unstable playback capability ordering');
  }
  return List.unmodifiable(values);
}

int? _nullableInteger(Object? raw, {required int maximum}) {
  if (raw == null) return null;
  if (raw is! int || raw < 1 || raw > maximum) {
    throw const FormatException('Invalid playback capability integer');
  }
  return raw;
}

bool _boolean(Object? raw) {
  if (raw is! bool) {
    throw const FormatException('Invalid playback capability boolean');
  }
  return raw;
}

bool? _nullableBoolean(Object? raw) {
  if (raw == null) return null;
  return _boolean(raw);
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final _mimeType = RegExp(
  r'^[a-z0-9][a-z0-9!#&^_.+-]{0,63}/[a-z0-9][a-z0-9!#&^_.+-]{0,127}$',
);
final _hdrType = RegExp(r'^(dolbyVision|hdr10|hdr10Plus|hlg|hlgPlus)$');
final _networkTransport = RegExp(
  r'^(bluetooth|cellular|ethernet|lowpan|satellite|thread|usb|vpn|wifi|wifiAware)$',
);
