import 'dart:io';

import '../../domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

bool _exactKeys(Map<String, dynamic> json, Set<String> keys) =>
    json.length == keys.length && json.keys.every(keys.contains);

String _objectId(Object? value) {
  final text = serverText(value, max: 32);
  if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(text)) _invalid();
  return text;
}

int _integer(Object? value, {int min = 0}) {
  if (value is! int || value < min || value > 0x7fffffffffffffff) {
    _invalid();
  }
  return value;
}

enum ServerEgressNetwork { public, lan }

enum ServerEgressScheme { http, https }

enum ServerComponentEgressComponent {
  homeAssistantProbe('home_assistant_probe'),
  proxmoxCommandWorker('proxmox_command_worker'),
  keeneticCommandWorker('keenetic_command_worker');

  const ServerComponentEgressComponent(this.wireName);
  final String wireName;
}

enum ServerEgressSource { coreApi, unknown }

enum ServerEgressReason {
  policyReplaced,
  grantMissing,
  dispatchAuthorized,
  probeCompleted,
  probeUnconfirmed,
  unknown,
}

enum ServerEgressCommand { replaceEgressPolicy, verifyService, unknown }

enum ServerEgressResult {
  accepted,
  denied,
  authorized,
  verified,
  unconfirmed,
  unknown,
}

T _enumWire<T extends Enum>(Iterable<T> values, Object? raw) {
  if (raw is! String) _invalid();
  String wire(T value) => value.name.replaceAllMapped(
    RegExp(r'[A-Z]'),
    (match) => '_${match[0]!.toLowerCase()}',
  );
  return values.where((value) => wire(value) == raw).firstOrNull ?? _invalid();
}

final class ServerComponentEgressAddress {
  const ServerComponentEgressAddress._(this.address, this.network);

  factory ServerComponentEgressAddress.fromJson(Map<String, dynamic> json) {
    if (!_exactKeys(json, {'address', 'network'})) _invalid();
    final address = serverText(json['address'], max: 45);
    if (address.contains('%')) _invalid();
    final parsed = InternetAddress.tryParse(address);
    if (parsed == null ||
        parsed.address.toLowerCase() != address.toLowerCase()) {
      _invalid();
    }
    final network = _enumWire(ServerEgressNetwork.values, json['network']);
    if (_addressNetwork(parsed) != network) _invalid();
    return ServerComponentEgressAddress._(address, network);
  }

  final String address;
  final ServerEgressNetwork network;

  Map<String, dynamic> toJson() => {
    'address': address,
    'network': network.name,
  };

  @override
  bool operator ==(Object other) =>
      other is ServerComponentEgressAddress &&
      address == other.address &&
      network == other.network;

  @override
  int get hashCode => Object.hash(address, network);

  @override
  String toString() => 'ServerComponentEgressAddress';
}

ServerEgressNetwork _addressNetwork(InternetAddress address) {
  final bytes = address.rawAddress;
  if (bytes.length == 4) {
    final first = bytes[0], second = bytes[1];
    final lan =
        first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
    if (lan) return ServerEgressNetwork.lan;
    final protocolAssignments =
        first == 192 &&
        second == 0 &&
        bytes[2] == 0 &&
        bytes[3] != 9 &&
        bytes[3] != 10;
    final documentation =
        (first == 192 && second == 0 && bytes[2] == 2) ||
        (first == 198 && second == 51 && bytes[2] == 100) ||
        (first == 203 && second == 0 && bytes[2] == 113);
    final benchmarking = first == 198 && (second == 18 || second == 19);
    if (first == 0 ||
        first == 127 ||
        first >= 224 ||
        (first == 169 && second == 254) ||
        (first == 100 && second >= 64 && second <= 127) ||
        protocolAssignments ||
        documentation ||
        benchmarking) {
      _invalid();
    }
    return ServerEgressNetwork.public;
  }
  final lan = (bytes[0] & 0xfe) == 0xfc;
  if (lan) {
    if (address.address.toLowerCase() == 'fd00:ec2::254') _invalid();
    return ServerEgressNetwork.lan;
  }
  final linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
  final multicast = bytes[0] == 0xff;
  final global = (bytes[0] & 0xe0) == 0x20;
  final transition6to4 = bytes[0] == 0x20 && bytes[1] == 0x02;
  final special2001 = bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] <= 0x01;
  final documentation2001 =
      bytes[0] == 0x20 &&
      bytes[1] == 0x01 &&
      bytes[2] == 0x0d &&
      bytes[3] == 0xb8;
  if (!global ||
      linkLocal ||
      multicast ||
      transition6to4 ||
      special2001 ||
      documentation2001) {
    _invalid();
  }
  return ServerEgressNetwork.public;
}

final class ServerComponentEgressGrant {
  const ServerComponentEgressGrant._({
    required this.scheme,
    required this.host,
    required this.port,
    required this.addresses,
  });

  factory ServerComponentEgressGrant.fromJson(Map<String, dynamic> json) {
    if (!_exactKeys(json, {'scheme', 'host', 'port', 'addresses'})) _invalid();
    final scheme = _enumWire(ServerEgressScheme.values, json['scheme']);
    final host = serverText(json['host'], max: 253);
    final port = _integer(json['port'], min: 1);
    final raw = json['addresses'];
    if (port > 65535 || raw is! List || raw.isEmpty || raw.length > 8) {
      _invalid();
    }
    final addresses = raw
        .map(
          (value) => ServerComponentEgressAddress.fromJson(serverObject(value)),
        )
        .toList(growable: false);
    if (addresses.map((value) => value.address).toSet().length !=
        addresses.length) {
      _invalid();
    }
    final authority = host.contains(':') ? '[$host]' : host;
    final uri = Uri.tryParse('${scheme.name}://$authority:$port');
    if (uri == null ||
        uri.host != host ||
        uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      _invalid();
    }
    final literal = InternetAddress.tryParse(host);
    if (literal != null &&
        (addresses.length != 1 ||
            addresses.single.address != literal.address)) {
      _invalid();
    }
    return ServerComponentEgressGrant._(
      scheme: scheme,
      host: host,
      port: port,
      addresses: List.unmodifiable(addresses),
    );
  }

  final ServerEgressScheme scheme;
  final String host;
  final int port;
  final List<ServerComponentEgressAddress> addresses;

  Map<String, dynamic> toJson() => {
    'scheme': scheme.name,
    'host': host,
    'port': port,
    'addresses': addresses.map((value) => value.toJson()).toList(),
  };

  @override
  bool operator ==(Object other) =>
      other is ServerComponentEgressGrant &&
      scheme == other.scheme &&
      host == other.host &&
      port == other.port &&
      _listEquals(addresses, other.addresses);

  @override
  int get hashCode =>
      Object.hash(scheme, host, port, Object.hashAll(addresses));

  @override
  String toString() => 'ServerComponentEgressGrant';
}

final class ServerComponentEgressPolicy {
  const ServerComponentEgressPolicy._({
    required this.component,
    required this.serviceId,
    required this.serviceRevision,
    required this.revision,
    required this.grants,
  });

  factory ServerComponentEgressPolicy.fromJson(Map<String, dynamic> json) {
    if (!_exactKeys(json, {
      'component',
      'serviceId',
      'serviceRevision',
      'revision',
      'grants',
    })) {
      _invalid();
    }
    final raw = json['grants'];
    if (raw is! List || raw.length > 1) _invalid();
    return ServerComponentEgressPolicy._(
      component:
          ServerComponentEgressComponent.values
              .where((value) => value.wireName == json['component'])
              .firstOrNull ??
          _invalid(),
      serviceId: _objectId(json['serviceId']),
      serviceRevision: _integer(json['serviceRevision'], min: 1),
      revision: _integer(json['revision']),
      grants: List.unmodifiable(
        raw.map(
          (value) => ServerComponentEgressGrant.fromJson(serverObject(value)),
        ),
      ),
    );
  }

  final ServerComponentEgressComponent component;
  final String serviceId;
  final int serviceRevision, revision;
  final List<ServerComponentEgressGrant> grants;

  @override
  String toString() => 'ServerComponentEgressPolicy';
}

final class ServerComponentEgressEvent {
  const ServerComponentEgressEvent._({
    required this.actorId,
    required this.serviceId,
    required this.serviceRevision,
    required this.correlationId,
    required this.policyRevision,
    required this.source,
    required this.reason,
    required this.command,
    required this.result,
    required this.timestamp,
  });

  factory ServerComponentEgressEvent.fromJson(Map<String, dynamic> json) {
    if (!_exactKeys(json, {
      'actorId',
      'serviceId',
      'serviceRevision',
      'correlationId',
      'policyRevision',
      'source',
      'reason',
      'command',
      'result',
      'timestamp',
    })) {
      _invalid();
    }
    final source = _enumWire(ServerEgressSource.values, json['source']);
    final reason = _enumWire(ServerEgressReason.values, json['reason']);
    final command = _enumWire(ServerEgressCommand.values, json['command']);
    final result = _enumWire(ServerEgressResult.values, json['result']);
    final serviceRevision = json['serviceRevision'] == null
        ? null
        : _integer(json['serviceRevision'], min: 1);
    const attribution = {
      ServerEgressReason.policyReplaced: (
        ServerEgressCommand.replaceEgressPolicy,
        ServerEgressResult.accepted,
      ),
      ServerEgressReason.grantMissing: (
        ServerEgressCommand.verifyService,
        ServerEgressResult.denied,
      ),
      ServerEgressReason.dispatchAuthorized: (
        ServerEgressCommand.verifyService,
        ServerEgressResult.authorized,
      ),
      ServerEgressReason.probeCompleted: (
        ServerEgressCommand.verifyService,
        ServerEgressResult.verified,
      ),
      ServerEgressReason.probeUnconfirmed: (
        ServerEgressCommand.verifyService,
        ServerEgressResult.unconfirmed,
      ),
    };
    if (source == ServerEgressSource.unknown) {
      if (reason != ServerEgressReason.unknown ||
          command != ServerEgressCommand.unknown ||
          result != ServerEgressResult.unknown ||
          serviceRevision != null) {
        _invalid();
      }
    } else if (serviceRevision == null ||
        attribution[reason] != (command, result)) {
      _invalid();
    }
    final timestamp = json['timestamp'];
    if (timestamp is! num || !timestamp.isFinite) _invalid();
    return ServerComponentEgressEvent._(
      actorId: _objectId(json['actorId']),
      serviceId: _objectId(json['serviceId']),
      serviceRevision: serviceRevision,
      correlationId: _objectId(json['correlationId']),
      policyRevision: _integer(json['policyRevision']),
      source: source,
      reason: reason,
      command: command,
      result: result,
      timestamp: timestamp.toDouble(),
    );
  }

  final String actorId, serviceId, correlationId;
  final int? serviceRevision;
  final int policyRevision;
  final ServerEgressSource source;
  final ServerEgressReason reason;
  final ServerEgressCommand command;
  final ServerEgressResult result;
  final double timestamp;

  @override
  String toString() => 'ServerComponentEgressEvent';
}

final class ServerComponentEgressResponse {
  const ServerComponentEgressResponse._(this.policy, this.audit);

  factory ServerComponentEgressResponse.fromJson(Map<String, dynamic> json) {
    if (!_exactKeys(json, {'schemaVersion', 'policy', 'audit'}) ||
        json['schemaVersion'] != 2) {
      _invalid();
    }
    final policy = ServerComponentEgressPolicy.fromJson(
      serverObject(json['policy']),
    );
    final raw = json['audit'];
    if (raw is! List || raw.length > 20) _invalid();
    final audit = raw
        .map(
          (value) => ServerComponentEgressEvent.fromJson(serverObject(value)),
        )
        .toList(growable: false);
    if (audit.any(
      (event) =>
          event.serviceId != policy.serviceId ||
          event.policyRevision > policy.revision,
    )) {
      _invalid();
    }
    return ServerComponentEgressResponse._(policy, List.unmodifiable(audit));
  }

  final ServerComponentEgressPolicy policy;
  final List<ServerComponentEgressEvent> audit;

  @override
  String toString() => 'ServerComponentEgressResponse';
}

bool _listEquals<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
