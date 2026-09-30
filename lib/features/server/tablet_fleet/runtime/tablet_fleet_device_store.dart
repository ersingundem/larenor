import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../../core/configuration_writes.dart';
import '../../domain/server_models.dart';
import '../domain/server_tablet_fleet_models.dart';

final class TabletFleetDeviceBinding {
  const TabletFleetDeviceBinding({
    required this.serverBaseUrl,
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamilyId,
  });

  factory TabletFleetDeviceBinding.fromJson(Object? value) {
    final json = serverObject(value);
    const keys = {
      'serverBaseUrl',
      'coreId',
      'homeId',
      'accountId',
      'sessionFamilyId',
    };
    if (json.length != keys.length || !json.keys.every(keys.contains)) {
      throw const LarenorServerException('invalid_storage');
    }
    String identity(String key) {
      final value = json[key];
      if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
        throw const LarenorServerException('invalid_storage');
      }
      return value;
    }

    final endpoint = ServerEndpoint(
      serverText(json['serverBaseUrl'], max: 2048),
    );
    return TabletFleetDeviceBinding(
      serverBaseUrl: endpoint.baseUrl,
      coreId: identity('coreId'),
      homeId: identity('homeId'),
      accountId: serverText(json['accountId'], max: 128),
      sessionFamilyId: identity('sessionFamilyId'),
    );
  }

  final String serverBaseUrl, coreId, homeId, accountId, sessionFamilyId;

  Map<String, Object?> toJson() => {
    'serverBaseUrl': serverBaseUrl,
    'coreId': coreId,
    'homeId': homeId,
    'accountId': accountId,
    'sessionFamilyId': sessionFamilyId,
  };

  @override
  bool operator ==(Object other) =>
      other is TabletFleetDeviceBinding &&
      serverBaseUrl == other.serverBaseUrl &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      sessionFamilyId == other.sessionFamilyId;

  @override
  int get hashCode =>
      Object.hash(serverBaseUrl, coreId, homeId, accountId, sessionFamilyId);
}

final class TabletFleetPendingCommand {
  const TabletFleetPendingCommand(this.command, this.result);

  factory TabletFleetPendingCommand.fromJson(Object? value) {
    final json = serverObject(value);
    if (json.length != 2 ||
        !json.containsKey('command') ||
        !json.containsKey('result')) {
      throw const LarenorServerException('invalid_storage');
    }
    final result = json['result'];
    final parsed = result == null ? null : TabletCommandResult.parse(result);
    if (parsed == TabletCommandResult.expired) {
      throw const LarenorServerException('invalid_storage');
    }
    return TabletFleetPendingCommand(
      ManagedTabletCommand.fromJson(json['command']),
      parsed,
    );
  }

  final ManagedTabletCommand command;
  final TabletCommandResult? result;

  Map<String, Object?> toJson() => {
    'command': command.toJson(),
    'result': result?.name,
  };
}

final class TabletFleetDeviceRecord {
  const TabletFleetDeviceRecord._({
    required this.binding,
    required this.tablet,
    required this.after,
    required this.pending,
  });

  factory TabletFleetDeviceRecord.enrolled({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
  }) => TabletFleetDeviceRecord._(
    binding: binding,
    tablet: tablet,
    after: 0,
    pending: null,
  );

  factory TabletFleetDeviceRecord.fromJson(Object? value) {
    final json = serverObject(value);
    const keys = {'schemaVersion', 'binding', 'tablet', 'after', 'pending'};
    final after = json['after'];
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        json['schemaVersion'] != 1 ||
        after is! int ||
        after < 0 ||
        after > 9223372036854775807) {
      throw const LarenorServerException('invalid_storage');
    }
    final binding = TabletFleetDeviceBinding.fromJson(json['binding']);
    final tablet = ManagedTablet.fromJson(json['tablet']);
    if (tablet.context.coreId != binding.coreId ||
        tablet.context.homeId != binding.homeId) {
      throw const LarenorServerException('invalid_storage');
    }
    final pending = json['pending'] == null
        ? null
        : TabletFleetPendingCommand.fromJson(json['pending']);
    if (pending != null &&
        (pending.command.sequence <= after ||
            pending.command.policyRevision != tablet.desiredProfileRevision)) {
      throw const LarenorServerException('invalid_storage');
    }
    return TabletFleetDeviceRecord._(
      binding: binding,
      tablet: tablet,
      after: after,
      pending: pending,
    );
  }

  final TabletFleetDeviceBinding binding;
  final ManagedTablet tablet;
  final int after;
  final TabletFleetPendingCommand? pending;

  TabletFleetDeviceRecord withTablet(ManagedTablet value) =>
      TabletFleetDeviceRecord._(
        binding: binding,
        tablet: value,
        after: after,
        pending: pending,
      );

  TabletFleetDeviceRecord withPending(ManagedTabletCommand value) =>
      TabletFleetDeviceRecord._(
        binding: binding,
        tablet: tablet,
        after: after,
        pending: TabletFleetPendingCommand(value, null),
      );

  TabletFleetDeviceRecord withPendingResult(TabletCommandResult value) {
    final current = pending;
    if (current == null || value == TabletCommandResult.expired) {
      throw const LarenorServerException('invalid_storage');
    }
    return TabletFleetDeviceRecord._(
      binding: binding,
      tablet: tablet,
      after: after,
      pending: TabletFleetPendingCommand(current.command, value),
    );
  }

  TabletFleetDeviceRecord completePending() {
    final current = pending;
    if (current == null || current.result == null) {
      throw const LarenorServerException('invalid_storage');
    }
    return TabletFleetDeviceRecord._(
      binding: binding,
      tablet: tablet,
      after: current.command.sequence,
      pending: null,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'binding': binding.toJson(),
    'tablet': tablet.toJson(),
    'after': after,
    'pending': pending?.toJson(),
  };
}

abstract interface class TabletFleetDeviceStore {
  Future<TabletFleetDeviceRecord?> read();
  Future<void> write(TabletFleetDeviceRecord? value);
}

final class SecureTabletFleetDeviceStore implements TabletFleetDeviceStore {
  SecureTabletFleetDeviceStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const key = 'server_tablet_fleet_device_v1';
  static const _maximumBytes = 16 * 1024;
  final FlutterSecureStorage _storage;

  @override
  Future<TabletFleetDeviceRecord?> read() => ConfigurationWrites.run(() async {
    final raw = await _storage.read(key: key);
    if (raw == null) return null;
    try {
      if (utf8.encode(raw).length > _maximumBytes) {
        throw const LarenorServerException('invalid_storage');
      }
      return TabletFleetDeviceRecord.fromJson(jsonDecode(raw));
    } catch (_) {
      await _storage.delete(key: key);
      throw const LarenorServerException('storage_failed');
    }
  });

  @override
  Future<void> write(TabletFleetDeviceRecord? value) =>
      ConfigurationWrites.run(() async {
        if (value == null) {
          await _storage.delete(key: key);
          return;
        }
        final raw = jsonEncode(value.toJson());
        if (utf8.encode(raw).length > _maximumBytes) {
          throw const LarenorServerException('storage_failed');
        }
        await _storage.write(key: key, value: raw);
      });
}
