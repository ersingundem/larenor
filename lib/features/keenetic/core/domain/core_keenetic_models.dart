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

Map _objectWithOptional(
  Object? raw,
  Set<String> required,
  Set<String> optional,
) {
  if (raw is! Map ||
      !required.every(raw.containsKey) ||
      raw.keys.any(
        (key) => !required.contains(key) && !optional.contains(key),
      )) {
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

int? _signal(Object? raw) {
  if (raw == null) return null;
  return _integer(raw, min: -127, max: 0);
}

String? _band(Object? raw) {
  if (raw == null) return null;
  if (raw is! String || !const {'2.4', '5', '6'}.contains(raw)) _invalid();
  return raw;
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
    this.firmwareRevision,
    this.statusRevision,
    this.cpuPercent,
    this.memoryPercent,
  );
  final bool online;
  final String? publicIp, firmware;
  final int uptimeSeconds;
  final int? firmwareRevision, statusRevision;
  final double? cpuPercent, memoryPercent;
  factory CoreKeeneticStatus.fromJson(Object? raw) {
    final value = _objectWithOptional(
      raw,
      {
        'online',
        'publicIp',
        'uptimeSeconds',
        'firmware',
        'cpuPercent',
        'memoryPercent',
      },
      {'firmwareRevision', 'statusRevision'},
    );
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
      value['firmwareRevision'] == null
          ? null
          : _integer(value['firmwareRevision'], min: 1),
      value['statusRevision'] == null
          ? null
          : _integer(value['statusRevision'], min: 1),
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
    this.guest,
    this.ssid,
    this.band,
    this.channel,
    this.signalDbm,
  );
  final String id, name;
  final CoreKeeneticInterfaceKind kind;
  final bool online;
  final String? address;
  final int rxBytes, txBytes;
  final bool? guest;
  final String? ssid, band;
  final int? channel, signalDbm;
  factory CoreKeeneticInterface.fromJson(Object? raw) {
    final value = _objectWithOptional(
      raw,
      {'id', 'name', 'kind', 'online', 'address', 'rxBytes', 'txBytes'},
      {'guest', 'ssid', 'band', 'channel', 'signalDbm'},
    );
    final kind = CoreKeeneticInterfaceKind.values
        .where((v) => v.name == value['kind'])
        .firstOrNull;
    if (kind == null ||
        value['online'] is! bool ||
        value.containsKey('guest') && value['guest'] is! bool) {
      _invalid();
    }
    final address = value['address'] == null
        ? null
        : _text(value['address'], max: 64);
    if (address != null && InternetAddress.tryParse(address) == null) {
      _invalid();
    }
    final ssid = value['ssid'] == null ? null : _text(value['ssid'], max: 64);
    final band = _band(value['band']);
    final channel = value['channel'] == null
        ? null
        : _integer(value['channel'], min: 1, max: 233);
    final signal = _signal(value['signalDbm']);
    if (kind != CoreKeeneticInterfaceKind.wifi &&
        (ssid != null || band != null || channel != null || signal != null)) {
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
      value['guest'] as bool?,
      ssid,
      band,
      channel,
      signal,
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
    this.internetAccess,
    this.band,
    this.signalDbm,
  );
  final String id, name, ipAddress, macAddress, interfaceId;
  final bool online, registered;
  final String? internetAccess;
  final String? band;
  final int? signalDbm;
  factory CoreKeeneticHost.fromJson(Object? raw) {
    final value = _objectWithOptional(
      raw,
      {
        'id',
        'name',
        'ipAddress',
        'macAddress',
        'interfaceId',
        'online',
        'registered',
      },
      {'internetAccess', 'band', 'signalDbm'},
    );
    final ip = _text(value['ipAddress'], max: 64),
        mac = _text(value['macAddress'], max: 17);
    if (InternetAddress.tryParse(ip) == null ||
        !RegExp(r'^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$').hasMatch(mac) ||
        value['online'] is! bool ||
        value['registered'] is! bool ||
        value.containsKey('internetAccess') &&
            !{'allowed', 'paused'}.contains(value['internetAccess'])) {
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
      value['internetAccess'] as String?,
      _band(value['band']),
      _signal(value['signalDbm']),
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
  int get pausedHosts =>
      hosts.where((h) => h.internetAccess == 'paused').length;
  List<CoreKeeneticInterface> get guestInterfaces =>
      interfaces.where((item) => item.guest == true).toList(growable: false);
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

sealed class CoreKeeneticDetail {
  const CoreKeeneticDetail(this.id, this.name, this.online);
  final String id, name;
  final bool online;
}

final class CoreKeeneticInterfaceDetail extends CoreKeeneticDetail {
  const CoreKeeneticInterfaceDetail._(
    super.id,
    super.name,
    super.online,
    this.interfaceKind,
    this.address,
    this.rxBytes,
    this.txBytes,
    this.guest,
    this.ssid,
    this.band,
    this.channel,
    this.signalDbm,
  );
  final CoreKeeneticInterfaceKind interfaceKind;
  final String? address, ssid, band;
  final int rxBytes, txBytes;
  final int? channel, signalDbm;
  final bool? guest;

  factory CoreKeeneticInterfaceDetail.fromJson(Object? raw) {
    final value = _object(raw, {
      'kind',
      'id',
      'name',
      'interfaceKind',
      'online',
      'address',
      'rxBytes',
      'txBytes',
      'guest',
      'ssid',
      'band',
      'channel',
      'signalDbm',
    });
    final kind = CoreKeeneticInterfaceKind.values
        .where((item) => item.name == value['interfaceKind'])
        .firstOrNull;
    if (value['kind'] != 'interface' ||
        kind == null ||
        value['online'] is! bool ||
        value['guest'] != null && value['guest'] is! bool) {
      _invalid();
    }
    final address = value['address'] == null
        ? null
        : _text(value['address'], max: 64);
    if (address != null && InternetAddress.tryParse(address) == null) {
      _invalid();
    }
    final ssid = value['ssid'] == null ? null : _text(value['ssid'], max: 64);
    final band = _band(value['band']);
    final channel = value['channel'] == null
        ? null
        : _integer(value['channel'], min: 1, max: 233);
    final signal = _signal(value['signalDbm']);
    if (kind != CoreKeeneticInterfaceKind.wifi &&
        (ssid != null || band != null || channel != null || signal != null)) {
      _invalid();
    }
    return CoreKeeneticInterfaceDetail._(
      _text(value['id'], max: 128),
      _text(value['name'], max: 128),
      value['online'] as bool,
      kind,
      address,
      _integer(value['rxBytes']),
      _integer(value['txBytes']),
      value['guest'] as bool?,
      ssid,
      band,
      channel,
      signal,
    );
  }
}

final class CoreKeeneticClientDetail extends CoreKeeneticDetail {
  const CoreKeeneticClientDetail._(
    super.id,
    super.name,
    super.online,
    this.ipAddress,
    this.macHash,
    this.interfaceId,
    this.registered,
    this.internetAccess,
    this.band,
    this.signalDbm,
  );
  final String ipAddress, macHash, interfaceId;
  final bool registered;
  final String? internetAccess, band;
  final int? signalDbm;

  factory CoreKeeneticClientDetail.fromJson(Object? raw) {
    final value = _object(raw, {
      'kind',
      'id',
      'name',
      'ipAddress',
      'macHash',
      'interfaceId',
      'online',
      'registered',
      'internetAccess',
      'band',
      'signalDbm',
    });
    final ip = _text(value['ipAddress'], max: 64);
    final id = _text(value['id'], max: 16);
    final hash = _text(value['macHash'], max: 16);
    if (value['kind'] != 'client' ||
        id != hash ||
        !RegExp(r'^[0-9a-f]{16}$').hasMatch(hash) ||
        InternetAddress.tryParse(ip) == null ||
        value['online'] is! bool ||
        value['registered'] is! bool ||
        value['internetAccess'] != null &&
            !const {'allowed', 'paused'}.contains(value['internetAccess'])) {
      _invalid();
    }
    return CoreKeeneticClientDetail._(
      id,
      _text(value['name'], max: 128),
      value['online'] as bool,
      ip,
      hash,
      _text(value['interfaceId'], max: 128),
      value['registered'] as bool,
      value['internetAccess'] as String?,
      _band(value['band']),
      _signal(value['signalDbm']),
    );
  }
}

final class CoreKeeneticDetailsPage {
  const CoreKeeneticDetailsPage._(this.entries, this.snapshot, this.nextAfter);
  final List<CoreKeeneticDetail> entries;
  final String snapshot;
  final String? nextAfter;
  List<CoreKeeneticInterfaceDetail> get interfaces =>
      entries.whereType<CoreKeeneticInterfaceDetail>().toList(growable: false);
  List<CoreKeeneticClientDetail> get clients =>
      entries.whereType<CoreKeeneticClientDetail>().toList(growable: false);

  factory CoreKeeneticDetailsPage.fromJson(Object? raw) {
    final value = _object(raw, {'entries', 'snapshot', 'nextAfter'});
    final rawEntries = value['entries'];
    if (rawEntries is! List || rawEntries.length > 100) _invalid();
    final entries = rawEntries
        .map<CoreKeeneticDetail>((item) {
          if (item is! Map) _invalid();
          return switch (item['kind']) {
            'interface' => CoreKeeneticInterfaceDetail.fromJson(item),
            'client' => CoreKeeneticClientDetail.fromJson(item),
            _ => _invalid(),
          };
        })
        .toList(growable: false);
    if (entries
            .map((item) => '${item.runtimeType}:${item.id}')
            .toSet()
            .length !=
        entries.length) {
      _invalid();
    }
    String digest(Object? candidate) {
      if (candidate is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(candidate)) {
        _invalid();
      }
      return candidate;
    }

    return CoreKeeneticDetailsPage._(
      List.unmodifiable(entries),
      digest(value['snapshot']),
      value['nextAfter'] == null ? null : digest(value['nextAfter']),
    );
  }

  CoreKeeneticDetailsPage append(CoreKeeneticDetailsPage next) {
    if (snapshot != next.snapshot ||
        entries.length + next.entries.length > 576) {
      _invalid();
    }
    final combined = [...entries, ...next.entries];
    if (combined
            .map((item) => '${item.runtimeType}:${item.id}')
            .toSet()
            .length !=
        combined.length) {
      _invalid();
    }
    return CoreKeeneticDetailsPage._(
      List.unmodifiable(combined),
      snapshot,
      next.nextAfter,
    );
  }
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

enum CoreKeeneticMeshRole { controller, extender }

enum CoreKeeneticBackhaul { ethernet, wifi_2_4, wifi_5, wifi_6, unknown }

enum CoreKeeneticBackhaulQuality { excellent, good, fair, poor, unknown }

final class CoreKeeneticMeshNode {
  const CoreKeeneticMeshNode._(
    this.id,
    this.name,
    this.model,
    this.role,
    this.online,
    this.parentId,
    this.backhaul,
    this.quality,
    this.pathCost,
  );
  final String id, name, model;
  final CoreKeeneticMeshRole role;
  final bool online;
  final String? parentId;
  final CoreKeeneticBackhaul? backhaul;
  final CoreKeeneticBackhaulQuality? quality;
  final int? pathCost;

  factory CoreKeeneticMeshNode.fromJson(Object? raw) {
    final value = _object(raw, {
      'id',
      'name',
      'model',
      'role',
      'online',
      'parentId',
      'backhaulType',
      'backhaulQuality',
      'pathCost',
    });
    String identity(Object? candidate) {
      if (candidate is! String ||
          !RegExp(r'^[0-9a-f]{16}$').hasMatch(candidate)) {
        _invalid();
      }
      return candidate;
    }

    final role = CoreKeeneticMeshRole.values
        .where((item) => item.name == value['role'])
        .firstOrNull;
    final backhaul = CoreKeeneticBackhaul.values
        .where((item) => item.name == value['backhaulType'])
        .firstOrNull;
    final quality = CoreKeeneticBackhaulQuality.values
        .where((item) => item.name == value['backhaulQuality'])
        .firstOrNull;
    if (role == null || value['online'] is! bool) _invalid();
    final parent = value['parentId'] == null
        ? null
        : identity(value['parentId']);
    final cost = value['pathCost'] == null
        ? null
        : _integer(value['pathCost'], min: 1, max: 65535);
    if (role == CoreKeeneticMeshRole.controller &&
            (parent != null ||
                backhaul != null ||
                quality != null ||
                cost != null) ||
        role == CoreKeeneticMeshRole.extender &&
            (parent == null ||
                backhaul == null ||
                quality == null ||
                cost == null)) {
      _invalid();
    }
    return CoreKeeneticMeshNode._(
      identity(value['id']),
      _text(value['name'], max: 128),
      _text(value['model'], max: 128),
      role,
      value['online'] as bool,
      parent,
      backhaul,
      quality,
      cost,
    );
  }
}

final class CoreKeeneticWifiDistribution {
  const CoreKeeneticWifiDistribution._(
    this.id,
    this.ssid,
    this.band,
    this.channel,
    this.clientCount,
    this.online,
  );
  final String id, ssid, band;
  final int channel, clientCount;
  final bool online;
  factory CoreKeeneticWifiDistribution.fromJson(Object? raw) {
    final value = _object(raw, {
      'id',
      'ssid',
      'band',
      'channel',
      'clientCount',
      'online',
    });
    if (value['online'] is! bool) _invalid();
    return CoreKeeneticWifiDistribution._(
      _text(value['id'], max: 128),
      _text(value['ssid'], max: 64),
      _band(value['band'])!,
      _integer(value['channel'], min: 1, max: 233),
      _integer(value['clientCount'], max: 512),
      value['online'] as bool,
    );
  }
}

final class CoreKeeneticTopologySnapshot {
  const CoreKeeneticTopologySnapshot._(
    this.bindingId,
    this.bindingRevision,
    this.serviceId,
    this.serviceRevision,
    this.resourceRevision,
    this.aclRevision,
    this.observedAt,
    this.remainingTtlMs,
    this.nodes,
    this.networks,
  );
  final String bindingId, serviceId;
  final int bindingRevision,
      serviceRevision,
      resourceRevision,
      aclRevision,
      remainingTtlMs;
  final DateTime observedAt;
  final List<CoreKeeneticMeshNode> nodes;
  final List<CoreKeeneticWifiDistribution> networks;

  factory CoreKeeneticTopologySnapshot.fromJson(
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
      'nodes',
      'networks',
    });
    _ref(value['ref'], target);
    final rawNodes = value['nodes'], rawNetworks = value['networks'];
    if (rawNodes is! List ||
        rawNodes.isEmpty ||
        rawNodes.length > 64 ||
        rawNetworks is! List ||
        rawNetworks.length > 64) {
      _invalid();
    }
    final nodes = rawNodes.map(CoreKeeneticMeshNode.fromJson).toList();
    final networks = rawNetworks
        .map(CoreKeeneticWifiDistribution.fromJson)
        .toList();
    final ids = nodes.map((item) => item.id).toSet();
    if (ids.length != nodes.length ||
        nodes
                .where((item) => item.role == CoreKeeneticMeshRole.controller)
                .length !=
            1 ||
        nodes.any(
          (item) => item.parentId != null && !ids.contains(item.parentId),
        ) ||
        networks.map((item) => item.id).toSet().length != networks.length) {
      _invalid();
    }
    final timestamp = value['observedAt'];
    final date = timestamp is String ? DateTime.tryParse(timestamp) : null;
    if (date == null ||
        !date.isUtc ||
        !RegExp(r'T.*(?:Z|\+00:00)$').hasMatch(timestamp as String)) {
      _invalid();
    }
    return CoreKeeneticTopologySnapshot._(
      _id(value['bindingId']),
      _integer(value['bindingRevision'], min: 1),
      _id(value['serviceId']),
      _integer(value['serviceRevision'], min: 1),
      _integer(value['resourceRevision'], min: target.revision),
      _integer(value['aclRevision'], min: target.aclRevision),
      date,
      _integer(value['remainingTtlMs'], max: 5000),
      List.unmodifiable(nodes),
      List.unmodifiable(networks),
    );
  }
}
