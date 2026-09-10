import '../../home_resources/domain/home_resource_models.dart';
import '../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map _object(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    _invalid();
  }
  return value;
}

String _id(Object? value) {
  if (value is! String ||
      value.length != 32 ||
      !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _integer(Object? value, {int min = 0, int max = 9223372036854775807}) {
  if (value is! int || value < min || value > max) _invalid();
  return value;
}

double _ratio(Object? value) {
  if (value is! num || !value.isFinite || value < 0 || value > 1) _invalid();
  return value.toDouble();
}

String _safe(Object? value, {int max = 128, Pattern? pattern}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      value.runes.any(
        (rune) =>
            rune < 32 ||
            rune >= 127 && rune <= 159 ||
            rune >= 0xd800 && rune <= 0xdfff,
      ) ||
      pattern != null && !RegExp(pattern.toString()).hasMatch(value)) {
    _invalid();
  }
  return value;
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
      target.kind != HomeResourceKind.resource ||
      value['kind'] != 'resource' ||
      value['coreId'] != target.context.coreId ||
      value['homeId'] != target.context.homeId ||
      value['id'] != target.id) {
    _invalid();
  }
}

DateTime _timestamp(Object? raw) {
  if (raw is! String ||
      raw.length > 40 ||
      !RegExp(r'T.*(?:Z|\+00:00)$').hasMatch(raw)) {
    _invalid();
  }
  final value = DateTime.tryParse(raw);
  if (value == null || !value.isUtc) _invalid();
  return value;
}

enum CoreProxmoxNodeStatus { online, offline }

final class CoreProxmoxNode {
  const CoreProxmoxNode._({
    required this.name,
    required this.status,
    required this.cpuRatio,
    required this.memoryUsedBytes,
    required this.memoryTotalBytes,
    required this.uptime,
  });
  final String name;
  final CoreProxmoxNodeStatus status;
  final double cpuRatio;
  final int memoryUsedBytes, memoryTotalBytes;
  final Duration uptime;

  factory CoreProxmoxNode.fromJson(Object? raw) {
    final value = _object(raw, {
      'node',
      'status',
      'cpuRatio',
      'memoryUsedBytes',
      'memoryTotalBytes',
      'uptimeSeconds',
    });
    final used = _integer(value['memoryUsedBytes']),
        total = _integer(value['memoryTotalBytes'], min: 1),
        uptime = _integer(value['uptimeSeconds']);
    if (used > total) _invalid();
    return CoreProxmoxNode._(
      name: _safe(value['node'], max: 64),
      status: switch (value['status']) {
        'online' => CoreProxmoxNodeStatus.online,
        'offline' => CoreProxmoxNodeStatus.offline,
        _ => _invalid(),
      },
      cpuRatio: _ratio(value['cpuRatio']),
      memoryUsedBytes: used,
      memoryTotalBytes: total,
      uptime: Duration(seconds: uptime),
    );
  }
}

enum CoreProxmoxGuestKind { qemu, lxc }

enum CoreProxmoxGuestStatus { running, stopped }

final class CoreProxmoxGuest {
  const CoreProxmoxGuest._({
    required this.vmId,
    required this.node,
    required this.kind,
    required this.name,
    required this.status,
    required this.cpuRatio,
    required this.memoryUsedBytes,
    required this.memoryTotalBytes,
  });
  final int vmId;
  final String node, name;
  final CoreProxmoxGuestKind kind;
  final CoreProxmoxGuestStatus status;
  final double cpuRatio;
  final int memoryUsedBytes, memoryTotalBytes;

  factory CoreProxmoxGuest.fromJson(Object? raw) {
    final value = _object(raw, {
      'vmId',
      'node',
      'kind',
      'name',
      'status',
      'cpuRatio',
      'memoryUsedBytes',
      'memoryTotalBytes',
    });
    final used = _integer(value['memoryUsedBytes']),
        total = _integer(value['memoryTotalBytes'], min: 1);
    if (used > total) _invalid();
    return CoreProxmoxGuest._(
      vmId: _integer(value['vmId'], min: 1, max: 999999999),
      node: _safe(value['node'], max: 64),
      kind: switch (value['kind']) {
        'qemu' => CoreProxmoxGuestKind.qemu,
        'lxc' => CoreProxmoxGuestKind.lxc,
        _ => _invalid(),
      },
      name: _safe(value['name']),
      status: switch (value['status']) {
        'running' => CoreProxmoxGuestStatus.running,
        'stopped' => CoreProxmoxGuestStatus.stopped,
        _ => _invalid(),
      },
      cpuRatio: _ratio(value['cpuRatio']),
      memoryUsedBytes: used,
      memoryTotalBytes: total,
    );
  }
}

final class CoreProxmoxStorage {
  const CoreProxmoxStorage._({
    required this.name,
    required this.node,
    required this.kind,
    required this.active,
    required this.usedBytes,
    required this.totalBytes,
    required this.availableBytes,
  });
  final String name, node, kind;
  final bool active;
  final int usedBytes, totalBytes, availableBytes;
  double get usedRatio => usedBytes / totalBytes;

  factory CoreProxmoxStorage.fromJson(Object? raw) {
    final value = _object(raw, {
      'storage',
      'node',
      'kind',
      'active',
      'usedBytes',
      'totalBytes',
      'availableBytes',
    });
    final used = _integer(value['usedBytes']),
        total = _integer(value['totalBytes'], min: 1),
        available = _integer(value['availableBytes']);
    if (value['active'] is! bool || used > total || available > total) {
      _invalid();
    }
    return CoreProxmoxStorage._(
      name: _safe(value['storage'], max: 64),
      node: _safe(value['node'], max: 64),
      kind: _safe(value['kind'], max: 64),
      active: value['active'] as bool,
      usedBytes: used,
      totalBytes: total,
      availableBytes: available,
    );
  }
}

final class CoreProxmoxSummary {
  const CoreProxmoxSummary._(this.nodes, this.guests, this.storages);
  final List<CoreProxmoxNode> nodes;
  final List<CoreProxmoxGuest> guests;
  final List<CoreProxmoxStorage> storages;

  factory CoreProxmoxSummary.fromJson(Object? raw) {
    final value = _object(raw, {'nodes', 'guests', 'storages'});
    List<T> list<T>(String key, int max, T Function(Object?) parse) {
      final source = value[key];
      if (source is! List || source.length > max) _invalid();
      return List<T>.unmodifiable(source.map(parse));
    }

    final nodes = list('nodes', 32, CoreProxmoxNode.fromJson),
        guests = list('guests', 256, CoreProxmoxGuest.fromJson),
        storages = list('storages', 64, CoreProxmoxStorage.fromJson);
    if (nodes.map((e) => e.name).toSet().length != nodes.length ||
        guests.map((e) => '${e.kind.name}:${e.vmId}').toSet().length !=
            guests.length ||
        storages.map((e) => '${e.node}:${e.name}').toSet().length !=
            storages.length) {
      _invalid();
    }
    return CoreProxmoxSummary._(nodes, guests, storages);
  }
}

final class CoreProxmoxBinding {
  const CoreProxmoxBinding._({
    required this.id,
    required this.revision,
    required this.target,
    required this.serviceId,
    required this.serviceRevision,
  });
  final String id, serviceId;
  final int revision, serviceRevision;
  final HomeResourceRecord target;

  factory CoreProxmoxBinding.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'id',
      'revision',
      'ref',
      'serviceId',
      'serviceRevision',
    });
    if (value['schemaVersion'] != 1) _invalid();
    _ref(value['ref'], target);
    return CoreProxmoxBinding._(
      id: _id(value['id']),
      revision: _integer(value['revision'], min: 1),
      target: target,
      serviceId: _id(value['serviceId']),
      serviceRevision: _integer(value['serviceRevision'], min: 1),
    );
  }

  bool sameBinding(CoreProxmoxBinding other) =>
      id == other.id &&
      revision == other.revision &&
      target.id == other.target.id &&
      target.context == other.target.context &&
      serviceId == other.serviceId &&
      serviceRevision == other.serviceRevision;
}

final class CoreProxmoxPreview {
  const CoreProxmoxPreview._(
    this.id,
    this.expiresInMs,
    this.binding,
    this.summary,
  );
  final String id;
  final int expiresInMs;
  final CoreProxmoxBinding binding;
  final CoreProxmoxSummary summary;

  factory CoreProxmoxPreview.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {'id', 'expiresInMs', 'binding', 'summary'});
    return CoreProxmoxPreview._(
      _id(value['id']),
      _integer(value['expiresInMs'], min: 1, max: 60000),
      CoreProxmoxBinding.fromJson(value['binding'], target: target),
      CoreProxmoxSummary.fromJson(value['summary']),
    );
  }
}

final class CoreProxmoxSnapshot {
  const CoreProxmoxSnapshot._({
    required this.bindingId,
    required this.bindingRevision,
    required this.resourceRevision,
    required this.aclRevision,
    required this.serviceId,
    required this.serviceRevision,
    required this.observedAt,
    required this.remainingTtlMs,
    required this.summary,
  });
  final String bindingId, serviceId;
  final int bindingRevision,
      resourceRevision,
      aclRevision,
      serviceRevision,
      remainingTtlMs;
  final DateTime observedAt;
  final CoreProxmoxSummary summary;
  Duration get remainingTtl => Duration(milliseconds: remainingTtlMs);

  factory CoreProxmoxSnapshot.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'ref',
      'bindingId',
      'bindingRevision',
      'resourceRevision',
      'aclRevision',
      'serviceId',
      'serviceRevision',
      'observedAt',
      'remainingTtlMs',
      'summary',
    });
    if (value['schemaVersion'] != 1) _invalid();
    _ref(value['ref'], target);
    final resourceRevision = _integer(value['resourceRevision'], min: 1),
        aclRevision = _integer(value['aclRevision'], min: 1);
    if (resourceRevision != target.revision ||
        aclRevision != target.aclRevision) {
      _invalid();
    }
    return CoreProxmoxSnapshot._(
      bindingId: _id(value['bindingId']),
      bindingRevision: _integer(value['bindingRevision'], min: 1),
      resourceRevision: resourceRevision,
      aclRevision: aclRevision,
      serviceId: _id(value['serviceId']),
      serviceRevision: _integer(value['serviceRevision'], min: 1),
      observedAt: _timestamp(value['observedAt']),
      remainingTtlMs: _integer(value['remainingTtlMs'], max: 5000),
      summary: CoreProxmoxSummary.fromJson(value['summary']),
    );
  }

  @override
  String toString() => 'CoreProxmoxSnapshot';
}
