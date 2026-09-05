import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/wellbeing_models.dart';

abstract interface class WellbeingNativeApi {
  WellbeingSource get source;
  Future<WellbeingProviderStatus> probe();
  Future<WellbeingProviderStatus> requestReadPermissions(
    Set<WellbeingMetric> metrics,
  );
  Future<List<WellbeingReadResult>> read({
    required Set<WellbeingMetric> metrics,
    required DateTime start,
    required DateTime end,
    required String profileLabel,
  });
  Future<void> cancel();
  Future<void> openPermissionSettings();
}

class ChannelWellbeingNativeApi implements WellbeingNativeApi {
  ChannelWellbeingNativeApi({
    MethodChannel? channel,
    TargetPlatform? platform,
    DateTime Function()? now,
  }) : _channel = channel ?? const MethodChannel('larenor/wellbeing'),
       _platform = platform ?? defaultTargetPlatform,
       _now = now ?? DateTime.now;
  final MethodChannel _channel;
  final TargetPlatform _platform;
  final DateTime Function() _now;
  @override
  WellbeingSource get source => _platform == TargetPlatform.iOS
      ? WellbeingSource.healthKit
      : WellbeingSource.healthConnect;
  bool get _android => !kIsWeb && _platform == TargetPlatform.android;
  WellbeingProviderStatus _unsupported() => WellbeingProviderStatus(
    source: source,
    availability: !kIsWeb && _platform == TargetPlatform.iOS
        ? WellbeingAvailability.integrationPending
        : WellbeingAvailability.unsupportedPlatform,
    checkedAt: _now(),
  );

  @override
  Future<WellbeingProviderStatus> probe() async {
    if (!_android) return _unsupported();
    try {
      return parseStatus(
        await _channel.invokeMethod<Object?>('probe'),
        source,
        _now(),
      );
    } on MissingPluginException {
      return WellbeingProviderStatus(
        source: source,
        availability: WellbeingAvailability.integrationPending,
      );
    } catch (_) {
      throw const WellbeingException(WellbeingFailure.unavailable);
    }
  }

  @override
  Future<WellbeingProviderStatus> requestReadPermissions(
    Set<WellbeingMetric> metrics,
  ) async {
    if (!_android) return _unsupported();
    if (metrics.isEmpty || metrics.length > 3) {
      throw const WellbeingException(WellbeingFailure.invalidData);
    }
    try {
      return parseStatus(
        await _channel.invokeMethod<Object?>('requestReadPermissions', {
          'metrics': metrics.map((v) => v.name).toList(),
        }),
        source,
        _now(),
      );
    } catch (_) {
      throw const WellbeingException(WellbeingFailure.permission);
    }
  }

  @override
  Future<List<WellbeingReadResult>> read({
    required Set<WellbeingMetric> metrics,
    required DateTime start,
    required DateTime end,
    required String profileLabel,
  }) async {
    if (!_android) throw const WellbeingException(WellbeingFailure.unavailable);
    if (metrics.isEmpty ||
        metrics.length > 3 ||
        !start.isBefore(end) ||
        end.difference(start) > const Duration(days: 30) ||
        end.isAfter(_now().add(const Duration(minutes: 1)))) {
      throw const WellbeingException(WellbeingFailure.invalidData);
    }
    try {
      final raw = await _channel
          .invokeMethod<Object?>('read', {
            'metrics': metrics.map((v) => v.name).toList(),
            'startMillis': start.millisecondsSinceEpoch,
            'endMillis': end.millisecondsSinceEpoch,
            'maxRecords': 500,
          })
          .timeout(const Duration(seconds: 30));
      return parseResults(
        raw,
        metrics,
        source,
        profileLabel,
        _now(),
        start,
        end,
      );
    } on WellbeingException {
      rethrow;
    } on TimeoutException {
      await cancel();
      throw const WellbeingException(WellbeingFailure.timeout);
    } on PlatformException catch (error) {
      throw WellbeingException(switch (error.code) {
        'timeout' => WellbeingFailure.timeout,
        'cancelled' => WellbeingFailure.cancelled,
        'invalidData' => WellbeingFailure.invalidData,
        'permission' => WellbeingFailure.permission,
        'unavailable' => WellbeingFailure.unavailable,
        _ => WellbeingFailure.readFailed,
      });
    } catch (_) {
      throw const WellbeingException(WellbeingFailure.readFailed);
    }
  }

  @override
  Future<void> cancel() async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<void>('cancel');
    } catch (_) {
      /* Best effort; caller also invalidates its epoch. */
    }
  }

  @override
  Future<void> openPermissionSettings() async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<void>('openPermissionSettings');
    } catch (_) {
      throw const WellbeingException(WellbeingFailure.unavailable);
    }
  }

  static WellbeingProviderStatus parseStatus(
    Object? raw,
    WellbeingSource source,
    DateTime now,
  ) {
    if (raw is! Map ||
        raw['availability'] is! String ||
        raw['permissions'] is! Map) {
      throw const WellbeingException(WellbeingFailure.invalidData);
    }
    final availability = WellbeingAvailability.values
        .where((v) => v.name == raw['availability'])
        .firstOrNull;
    final permissions = <WellbeingMetric, WellbeingPermission>{};
    if (availability == null || (raw['permissions'] as Map).length > 3) {
      throw const WellbeingException(WellbeingFailure.invalidData);
    }
    for (final entry in (raw['permissions'] as Map).entries) {
      final metric = WellbeingMetric.values
          .where((v) => v.name == entry.key)
          .firstOrNull;
      final permission = WellbeingPermission.values
          .where((v) => v.name == entry.value)
          .firstOrNull;
      if (metric == null || permission == null) {
        throw const WellbeingException(WellbeingFailure.invalidData);
      }
      permissions[metric] = source == WellbeingSource.healthKit
          ? WellbeingPermission.unknown
          : permission;
    }
    return WellbeingProviderStatus(
      source: source,
      availability: availability,
      permissions: permissions,
      checkedAt: now,
    );
  }

  static List<WellbeingReadResult> parseResults(
    Object? raw,
    Set<WellbeingMetric> metrics,
    WellbeingSource source,
    String profileLabel,
    DateTime now,
    DateTime start,
    DateTime end,
  ) {
    Never invalid() =>
        throw const WellbeingException(WellbeingFailure.invalidData);
    if (raw is! List || raw.length != metrics.length) invalid();
    final seen = <WellbeingMetric>{}, records = <String>{};
    final output = <WellbeingReadResult>[];
    var total = 0;
    for (final result in raw) {
      if (result is! Map ||
          result['records'] is! List ||
          result['truncated'] is! bool) {
        invalid();
      }
      final metric = WellbeingMetric.values
          .where((v) => v.name == result['metric'])
          .firstOrNull;
      final state = WellbeingReadState.values
          .where((v) => v.name == result['state'])
          .firstOrNull;
      if (metric == null ||
          !metrics.contains(metric) ||
          !seen.add(metric) ||
          state == null ||
          state == WellbeingReadState.unread) {
        invalid();
      }
      final list = result['records'] as List;
      total += list.length;
      if (total > 500 ||
          (state != WellbeingReadState.data && list.isNotEmpty) ||
          (state == WellbeingReadState.data && list.isEmpty)) {
        invalid();
      }
      final measurements = <WellbeingMeasurement>[];
      for (final record in list) {
        if (record is! Map) invalid();
        final value = record['value'],
            time = record['timeMillis'],
            id = record['id'];
        final origin = record['originName'], intervalEnd = record['endMillis'];
        if (value is! num ||
            !value.isFinite ||
            value < 0 ||
            time is! int ||
            (metric == WellbeingMetric.bodyFatPercentage && value > 100) ||
            (metric == WellbeingMetric.steps &&
                value != value.roundToDouble()) ||
            id is! String ||
            id.isEmpty ||
            id.length > 256 ||
            (origin != null &&
                (origin is! String ||
                    origin.length > 160 ||
                    RegExp(r'[\x00-\x1f\x7f]').hasMatch(origin)))) {
          invalid();
        }
        if (time < start.millisecondsSinceEpoch ||
            time >= end.millisecondsSinceEpoch) {
          invalid();
        }
        final date = DateTime.fromMillisecondsSinceEpoch(time, isUtc: true);
        DateTime? until;
        if (intervalEnd != null) {
          if (intervalEnd is! int ||
              intervalEnd <= time ||
              intervalEnd > end.millisecondsSinceEpoch) {
            invalid();
          }
          until = DateTime.fromMillisecondsSinceEpoch(intervalEnd, isUtc: true);
        }
        if (metric == WellbeingMetric.steps && until == null) invalid();
        if (!records.add('${metric.name}:$id')) continue;
        measurements.add(
          WellbeingMeasurement(
            source: source,
            metric: metric,
            value: value.toDouble(),
            unit: switch (metric) {
              WellbeingMetric.bodyMass => 'kg',
              WellbeingMetric.bodyFatPercentage => '%',
              WellbeingMetric.steps => 'count',
            },
            profileLabel: profileLabel,
            readAt: now,
            measuredAt: date,
            intervalEnd: until,
            sourceRecordId: id,
            originName: origin as String?,
          ),
        );
      }
      output.add(
        WellbeingReadResult(
          source: source,
          metric: metric,
          state:
              source == WellbeingSource.healthKit &&
                  state == WellbeingReadState.empty
              ? WellbeingReadState.emptyOrNotShared
              : state,
          measurements: measurements,
          readAt: now,
          failure: state == WellbeingReadState.failed
              ? switch (result['failure']) {
                  'permission' => WellbeingFailure.permission,
                  'unavailable' => WellbeingFailure.unavailable,
                  _ => WellbeingFailure.readFailed,
                }
              : null,
          truncated: result['truncated'] as bool,
        ),
      );
    }
    return List.unmodifiable(output);
  }
}
