import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/configuration_writes.dart';
import '../../server/domain/server_models.dart';

abstract interface class LocalNotificationStoreBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class SecureLocalNotificationStoreBackend
    implements LocalNotificationStoreBackend {
  SecureLocalNotificationStoreBackend([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

final class LocalNotificationStoredSubscription {
  const LocalNotificationStoredSubscription({
    required this.context,
    required this.actorId,
    required this.id,
    required this.revision,
    required this.expiresAt,
  });
  final ServerContext context;
  final String actorId, id;
  final int revision;
  final DateTime expiresAt;
  Map<String, Object> toJson() => {
    'version': 1,
    'context': context.toJson(),
    'actorId': actorId,
    'id': id,
    'revision': revision,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };
}

final class LocalNotificationStore {
  LocalNotificationStore({LocalNotificationStoreBackend? backend})
    : _backend = backend ?? SecureLocalNotificationStoreBackend();
  final LocalNotificationStoreBackend _backend;

  static void _check(bool Function() isCurrent) {
    try {
      if (isCurrent()) return;
    } catch (_) {}
    throw const LarenorServerException('cancelled');
  }

  static String key(ServerContext context, String actorId) =>
      'local_notification_subscription_v1_${sha256.convert(utf8.encode(jsonEncode([context.coreId, context.homeId, actorId])))}';

  static LocalNotificationStoredSubscription? _decode(
    String? raw,
    ServerContext expected,
    String actor,
  ) {
    if (raw == null) return null;
    try {
      if (utf8.encode(raw).length > 2048) throw const FormatException();
      final value = jsonDecode(raw);
      const keys = {
        'version',
        'context',
        'actorId',
        'id',
        'revision',
        'expiresAt',
      };
      if (value is! Map ||
          value.length != keys.length ||
          value.keys.any((item) => !keys.contains(item)) ||
          value['version'] != 1 ||
          value['actorId'] != actor ||
          ServerContext.fromJson(value['context']) != expected ||
          value['id'] is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(value['id']) ||
          value['revision'] is! int ||
          value['revision'] < 0 ||
          value['revision'] > 0x7fffffffffffffff ||
          value['expiresAt'] is! String) {
        throw const FormatException();
      }
      final expires = DateTime.parse(value['expiresAt']).toUtc();
      if (expires.toIso8601String() != value['expiresAt']) {
        throw const FormatException();
      }
      return LocalNotificationStoredSubscription(
        context: expected,
        actorId: actor,
        id: value['id'],
        revision: value['revision'],
        expiresAt: expires,
      );
    } catch (_) {
      throw const LarenorServerException('notification_store_invalid');
    }
  }

  Future<LocalNotificationStoredSubscription?> read(
    ServerContext context,
    String actor, {
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    _check(isCurrent);
    final raw = await _backend.read(key(context, actor));
    _check(isCurrent);
    return _decode(raw, context, actor);
  });

  Future<void> write(
    LocalNotificationStoredSubscription record, {
    required LocalNotificationStoredSubscription? before,
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    _check(isCurrent);
    final storageKey = key(record.context, record.actorId);
    final previous = await _backend.read(storageKey);
    final current = _decode(previous, record.context, record.actorId);
    _check(isCurrent);
    bool same(
      LocalNotificationStoredSubscription? a,
      LocalNotificationStoredSubscription? b,
    ) =>
        a?.context == b?.context &&
        a?.actorId == b?.actorId &&
        a?.id == b?.id &&
        a?.revision == b?.revision &&
        a?.expiresAt == b?.expiresAt;
    if (!same(current, before)) {
      throw const LarenorServerException('revision_conflict');
    }
    await _backend.write(storageKey, jsonEncode(record.toJson()));
    try {
      _check(isCurrent);
    } on LarenorServerException {
      if (previous == null) {
        await _backend.delete(storageKey);
      } else {
        await _backend.write(storageKey, previous);
      }
      rethrow;
    }
  });

  static LocalNotificationStoredSubscription create(
    ServerContext context,
    String actor,
    DateTime now,
  ) {
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return LocalNotificationStoredSubscription(
      context: context,
      actorId: actor,
      id: id,
      revision: 0,
      expiresAt: now.toUtc().add(const Duration(days: 30)),
    );
  }
}
