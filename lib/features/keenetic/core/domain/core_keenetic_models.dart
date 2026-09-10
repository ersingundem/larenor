import 'dart:io';

import '../../../home_resources/domain/home_resource_models.dart';
import '../../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');
Map _object(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    _invalid();
  }
  return raw;
}

String _id(Object? raw) {
  if (raw is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(raw)) _invalid();
  return raw;
}

String _text(Object? raw, {required int max}) {
  if (raw is! String ||
      raw.isEmpty ||
      raw.runes.length > max ||
      raw.runes.any(
        (r) =>
            r < 32 ||
            r >= 127 && r <= 159 ||
            r >= 0xd800 && r <= 0xdfff ||
            r >= 0x202a && r <= 0x202e ||
            r >= 0x2066 && r <= 0x2069 ||
            r == 0xfeff,
      )) {
    _invalid();
  }
  return raw;
}

int _integer(Object? raw, {int min = 0, int max = 0x7fffffffffffffff}) {
  if (raw is! int || raw < min || raw > max) _invalid();
  return raw;
}

double? _percent(Object? raw) {
  if (raw == null) return null;
  if (raw is! num || !raw.isFinite || raw < 0 || raw > 100) _invalid();
  return raw.toDouble();
}

void _ref(Object? raw, HomeResourceRecord target) {
  final value = _object(raw, {
    'schemaVersion',
    'coreId',
    'homeId',
    'kind',
    'id',
  });
  if (value['schemaVersion'] != 1 ||
      value['coreId'] != target.context.coreId ||
      value['homeId'] != target.context.homeId ||
      value['kind'] != 'resource' ||
      value['id'] != target.id ||
      target.kind != HomeResourceKind.resource) {
    _invalid();
  }
}

final class CoreKeeneticStatus {
  const CoreKeeneticStatus._(
    this.online,
    this.publicIp,
    this.uptimeSeconds,
    this.firmware,
    this.cpuPercent,
    this.memoryPercent,
  );
  final bool online;
  final String? publicIp, firmware;
  final int uptimeSeconds;
  final double? cpuPercent, memoryPercent;
  factory CoreKeeneticStatus.fromJson(Object? raw) {
    final value = _object(raw, {
      'online',
      'publicIp',
      'uptimeSeconds',
      'firmware',
      'cpuPercent',
      'memoryPercent',
    });
    if (value['online'] is! bool) _invalid();
    final publicIp = value['publicIp'] == null
        ? null
        : _text(value['publicIp'], max: 64);
    if (publicIp != null && InternetAddress.tryParse(publicIp) == null) {
      _invalid();
    }
    return CoreKeeneticStatus._(
      value['online'] as bool,
      publicIp,
      _integer(value['uptimeSeconds']),
      value['firmware'] == null ? null : _text(value['firmware'], max: 80),
      _percent(value['cpuPercent']),
      _percent(value['memoryPercent']),
    );
  }
}

enum CoreKeeneticInterfaceKind { wan, lan, wifi, vpn, other }

final class CoreKeeneticInterface {
  const CoreKeeneticInterface._(
    this.id,
    this.name,
    this.kind,
    this.online,
    this.address,
    this.rxBytes,
    this.txBytes,
  );
  final String id, name;
  final CoreKeeneticInterfaceKind kind;
  final bool online;
  final String? address;
  final int rxBytes, txBytes;
  factory CoreKeeneticInterface.fromJson(Object? raw) {
    final value = _object(raw, {
      'id',
      'name',
      'kind',
      'online',
      'address',
      'rxBytes',
      'txBytes',
    });
    final kind = CoreKeeneticInterfaceKind.values
        .where((v) => v.name == value['kind'])
        .firstOrNull;
    if (kind == null || value['online'] is! bool) _invalid();
    final address = value['address'] == null
        ? null
        : _text(value['address'], max: 64);
    if (address != null && InternetAddress.tryParse(address) == null) {
      _invalid();
    }
    return CoreKeeneticInterface._(
      _text(value['id'], max: 128),
      _text(value['name'], max: 128),
      kind,
      value['online'] as bool,
      address,
      _integer(value['rxBytes']),
      _integer(value['txBytes']),
    );
  }
}

final class CoreKeeneticTraffic {
  const CoreKeeneticTraffic._(
    this.rxBytes,
    this.txBytes,
    this.downloadBps,
    this.uploadBps,
  );
  final int rxBytes, txBytes;
  final int? downloadBps, uploadBps;
  factory CoreKeeneticTraffic.fromJson(Object? raw) {
    final value = _object(raw, {
      'rxBytes',
      'txBytes',
      'downloadBps',
      'uploadBps',
    });
    return CoreKeeneticTraffic._(
      _integer(value['rxBytes']),
      _integer(value['txBytes']),
      value['downloadBps'] == null ? null : _integer(value['downloadBps']),
      value['uploadBps'] == null ? null : _integer(value['uploadBps']),
    );
  }
}

final class CoreKeeneticHost {
  const CoreKeeneticHost._(
    this.id,
    this.name,
    this.ipAddress,
    this.macAddress,
    this.interfaceId,
    this.online,
    this.registered,
  );
  final String id, name, ipAddress, macAddress, interfaceId;
  final bool online, registered;
  factory CoreKeeneticHost.fromJson(Object? raw) {
    final value = _object(raw, {
      'id',
      'name',
      'ipAddress',
      'macAddress',
      'interfaceId',
      'online',
      'registered',
    });
    final ip = _text(value['ipAddress'], max: 64),
        mac = _text(value['macAddress'], max: 17);
    if (InternetAddress.tryParse(ip) == null ||
        !RegExp(r'^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$').hasMatch(mac) ||
        value['online'] is! bool ||
        value['registered'] is! bool) {
      _invalid();
    }
    return CoreKeeneticHost._(
      _text(value['id'], max: 128),
      _text(value['name'], max: 128),
      ip,
      mac,
      _text(value['interfaceId'], max: 128),
      value['online'] as bool,
      value['registered'] as bool,
    );
  }
}

final class CoreKeeneticTelemetry {
  const CoreKeeneticTelemetry._(
    this.status,
    this.interfaces,
    this.traffic,
    this.hosts,
  );
  final CoreKeeneticStatus status;
  final List<CoreKeeneticInterface> interfaces;
  final CoreKeeneticTraffic traffic;
  final List<CoreKeeneticHost> hosts;
  int get onlineHosts => hosts.where((h) => h.online).length;
  factory CoreKeeneticTelemetry.fromJson(Object? raw) {
    final value = _object(raw, {'status', 'interfaces', 'traffic', 'hosts'});
    final rawInterfaces = value['interfaces'], rawHosts = value['hosts'];
    if (rawInterfaces is! List ||
        rawInterfaces.isEmpty ||
        rawInterfaces.length > 64 ||
        rawHosts is! List ||
        rawHosts.length > 512) {
      _invalid();
    }
    final interfaces = rawInterfaces
            .map(CoreKeeneticInterface.fromJson)
            .toList(),
        hosts = rawHosts.map(CoreKeeneticHost.fromJson).toList();
    final ids = interfaces.map((i) => i.id).toSet();
    if (ids.length != interfaces.length ||
        hosts.map((h) => h.id).toSet().length != hosts.length ||
        hosts.any((h) => !ids.contains(h.interfaceId))) {
      _invalid();
    }
    return CoreKeeneticTelemetry._(
      CoreKeeneticStatus.fromJson(value['status']),
      List.unmodifiable(interfaces),
      CoreKeeneticTraffic.fromJson(value['traffic']),
      List.unmodifiable(hosts),
    );
  }
  @override
  String toString() => 'CoreKeeneticTelemetry';
}

final class CoreKeeneticBinding {
  const CoreKeeneticBinding._(
    this.id,
    this.revision,
    this.target,
    this.serviceId,
    this.serviceRevision,
  );
  final String id, serviceId;
  final int revision, serviceRevision;
  final HomeResourceRecord target;
  factory CoreKeeneticBinding.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {
      'id',
      'revision',
      'ref',
      'serviceId',
      'serviceRevision',
    });
    _ref(value['ref'], target);
    return CoreKeeneticBinding._(
      _id(value['id']),
      _integer(value['revision'], min: 1),
      target,
      _id(value['serviceId']),
      _integer(value['serviceRevision'], min: 1),
    );
  }
  bool sameBinding(CoreKeeneticBinding other) =>
      id == other.id &&
      revision == other.revision &&
      target.context == other.target.context &&
      target.id == other.target.id &&
      serviceId == other.serviceId &&
      serviceRevision == other.serviceRevision;
}

final class CoreKeeneticPreview {
  const CoreKeeneticPreview._(
    this.id,
    this.expiresInMs,
    this.binding,
    this.telemetry,
  );
  final String id;
  final int expiresInMs;
  final CoreKeeneticBinding binding;
  final CoreKeeneticTelemetry telemetry;
  factory CoreKeeneticPreview.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {'id', 'expiresInMs', 'binding', 'snapshot'});
    return CoreKeeneticPreview._(
      _id(value['id']),
      _integer(value['expiresInMs'], min: 1, max: 60000),
      CoreKeeneticBinding.fromJson(value['binding'], target: target),
      CoreKeeneticTelemetry.fromJson(value['snapshot']),
    );
  }
}

final class CoreKeeneticSnapshot {
  const CoreKeeneticSnapshot._(
    this.bindingId,
    this.bindingRevision,
    this.serviceId,
    this.serviceRevision,
    this.resourceRevision,
    this.aclRevision,
    this.observedAt,
    this.remainingTtlMs,
    this.telemetry,
  );
  final String bindingId, serviceId;
  final int bindingRevision,
      serviceRevision,
      resourceRevision,
      aclRevision,
      remainingTtlMs;
  final DateTime observedAt;
  final CoreKeeneticTelemetry telemetry;
  factory CoreKeeneticSnapshot.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {
      'ref',
      'bindingId',
      'bindingRevision',
      'serviceId',
      'serviceRevision',
      'resourceRevision',
      'aclRevision',
      'observedAt',
      'remainingTtlMs',
      'telemetry',
    });
    _ref(value['ref'], target);
    final timestamp = value['observedAt'];
    final date = timestamp is String ? DateTime.tryParse(timestamp) : null;
    if (date == null ||
        !date.isUtc ||
        !RegExp(r'T.*(?:Z|\+00:00)$').hasMatch(timestamp as String)) {
      _invalid();
    }
    return CoreKeeneticSnapshot._(
      _id(value['bindingId']),
      _integer(value['bindingRevision'], min: 1),
      _id(value['serviceId']),
      _integer(value['serviceRevision'], min: 1),
      _integer(value['resourceRevision'], min: target.revision),
      _integer(value['aclRevision'], min: target.aclRevision),
      date,
      _integer(value['remainingTtlMs'], max: 5000),
      CoreKeeneticTelemetry.fromJson(value['telemetry']),
    );
  }
}
