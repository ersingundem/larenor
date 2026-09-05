import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/configuration_writes.dart';
import '../../auth/data/ha_connection_config.dart';
import '../domain/wellbeing_models.dart';

String wellbeingAccountFingerprint(HaConnectionConfig config) => sha256
    .convert(utf8.encode('${config.baseUrl}\u0000${config.token}'))
    .toString();

bool validWellbeingLabel(String value) =>
    value.trim().isNotEmpty &&
    value.length <= 80 &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

bool validWellbeingEntityId(String value) =>
    value.length <= 255 && RegExp(r'^sensor\.[a-z0-9_]+$').hasMatch(value);

/// A captured private action can expire during platform I/O. Never expose a
/// callback exception or treat a late platform response as fresh authority.
void requireCurrentWellbeingAction(bool Function() isCurrent) {
  try {
    if (isCurrent()) return;
  } catch (_) {
    // Action callbacks contain no public diagnostic information.
  }
  throw const WellbeingException(WellbeingFailure.locked);
}

/// Separate secure namespace; never add this key to backup allowlists.
class WellbeingStore {
  WellbeingStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  static const storageKey = 'wellbeing_private_v1';
  final FlutterSecureStorage _storage;

  Future<WellbeingSettings> read() async {
    try {
      final raw = await _storage.read(key: storageKey);
      if (raw == null) return WellbeingSettings();
      if (raw.length > 32768) throw const FormatException();
      return decode(jsonDecode(raw));
    } catch (_) {
      throw const WellbeingException(WellbeingFailure.storageFailed);
    }
  }

  Future<void> save(
    WellbeingSettings settings, {
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    requireCurrentWellbeingAction(isCurrent);
    final encoded = encode(settings);
    requireCurrentWellbeingAction(isCurrent);
    try {
      await _storage.write(key: storageKey, value: jsonEncode(encoded));
    } catch (_) {
      throw const WellbeingException(WellbeingFailure.storageFailed);
    }
    requireCurrentWellbeingAction(isCurrent);
  });

  Future<void> clear({required bool Function() isCurrent}) =>
      ConfigurationWrites.run(() async {
        requireCurrentWellbeingAction(isCurrent);
        try {
          await _storage.delete(key: storageKey);
        } catch (_) {
          throw const WellbeingException(WellbeingFailure.storageFailed);
        }
        requireCurrentWellbeingAction(isCurrent);
      });

  static Map<String, dynamic> encode(WellbeingSettings settings) {
    final map = <String, dynamic>{
      'version': 1,
      'enabled': settings.enabled,
      'profileLabel': settings.profileLabel,
      'nativeMetrics': settings.nativeMetrics.map((v) => v.name).toList(),
      'bindings': [
        for (final b in settings.bindings)
          {
            'id': b.id,
            'accountFingerprint': b.accountFingerprint,
            'entityId': b.entityId,
            'metric': b.metric.name,
            'profileLabel': b.profileLabel,
          },
      ],
    };
    decode(map);
    return map;
  }

  static WellbeingSettings decode(Object? raw) {
    Never invalid() =>
        throw const WellbeingException(WellbeingFailure.invalidData);
    if (raw is! Map ||
        raw.length != 5 ||
        raw['version'] != 1 ||
        raw['enabled'] is! bool ||
        raw['profileLabel'] is! String ||
        raw['nativeMetrics'] is! List ||
        raw['bindings'] is! List) {
      invalid();
    }
    final label = raw['profileLabel'] as String;
    final metricsRaw = raw['nativeMetrics'] as List;
    final bindingsRaw = raw['bindings'] as List;
    if (metricsRaw.length > 3 || bindingsRaw.length > 32) invalid();
    final metrics = <WellbeingMetric>{};
    for (final name in metricsRaw) {
      final metric = WellbeingMetric.values
          .where((v) => v.name == name)
          .firstOrNull;
      if (metric == null || !metrics.add(metric)) invalid();
    }
    if ((label.isNotEmpty && !validWellbeingLabel(label)) ||
        (metrics.isNotEmpty && !validWellbeingLabel(label))) {
      invalid();
    }
    final bindings = <HaWellbeingBinding>[];
    final ids = <String>{}, entities = <String>{};
    for (final b in bindingsRaw) {
      if (b is! Map || b.length != 5) invalid();
      final id = b['id'], fingerprint = b['accountFingerprint'];
      final entityId = b['entityId'], profile = b['profileLabel'];
      final metric = WellbeingMetric.values
          .where((v) => v.name == b['metric'])
          .firstOrNull;
      if (id is! String ||
          !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id) ||
          !ids.add(id) ||
          fingerprint is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint) ||
          entityId is! String ||
          !validWellbeingEntityId(entityId) ||
          !entities.add('$fingerprint:$entityId') ||
          profile is! String ||
          !validWellbeingLabel(profile) ||
          metric == null ||
          metric == WellbeingMetric.steps) {
        invalid();
      }
      bindings.add(
        HaWellbeingBinding(
          id: id,
          accountFingerprint: fingerprint,
          entityId: entityId,
          metric: metric,
          profileLabel: profile,
        ),
      );
    }
    return WellbeingSettings(
      enabled: raw['enabled'] as bool,
      profileLabel: label,
      nativeMetrics: metrics,
      bindings: bindings,
    );
  }
}
