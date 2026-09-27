import '../../domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<Object?, Object?> _object(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    _invalid();
  }
  return raw;
}

String _id(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 9223372036854775807) {
    _invalid();
  }
  return value;
}

const serverMcpReadTool = 'home.resource_count.read';
const serverMcpWriteTool = 'home.note.create';
const serverMcpTools = {serverMcpReadTool, serverMcpWriteTool};

final class ServerMcpGrant {
  const ServerMcpGrant._({
    required this.id,
    required this.revision,
    required this.clientId,
    required this.clientName,
    required this.tools,
    required this.state,
    required this.expiresAt,
  });

  factory ServerMcpGrant.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'id',
      'revision',
      'clientId',
      'clientName',
      'tools',
      'state',
      'expiresAt',
      'createdAt',
      'updatedAt',
    });
    final clientId = value['clientId'];
    final clientName = value['clientName'];
    final rawTools = value['tools'];
    final state = value['state'];
    final expiresAt = value['expiresAt'];
    if (value['schemaVersion'] != 1 ||
        clientId is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{2,95}$').hasMatch(clientId) ||
        clientName is! String ||
        clientName.isEmpty ||
        clientName.runes.length > 80 ||
        rawTools is! List ||
        rawTools.isEmpty ||
        rawTools.length > 2 ||
        rawTools.any((tool) => !serverMcpTools.contains(tool)) ||
        rawTools.toSet().length != rawTools.length ||
        state != 'active' && state != 'revoked' && state != 'expired' ||
        expiresAt is! num ||
        !expiresAt.isFinite ||
        value['createdAt'] is! num ||
        value['updatedAt'] is! num) {
      _invalid();
    }
    final tools = List<String>.unmodifiable(rawTools.cast<String>());
    if (tools.join('\n') != ([...tools]..sort()).join('\n')) _invalid();
    return ServerMcpGrant._(
      id: _id(value['id']),
      revision: _revision(value['revision']),
      clientId: clientId,
      clientName: clientName,
      tools: tools,
      state: state as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (expiresAt * 1000).round(),
        isUtc: true,
      ),
    );
  }

  final String id, clientId, clientName, state;
  final int revision;
  final List<String> tools;
  final DateTime expiresAt;

  bool get active => state == 'active' && expiresAt.isAfter(DateTime.now());
}

final class ServerMcpGrantList {
  const ServerMcpGrantList._(this.grants);

  factory ServerMcpGrantList.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'catalogVersion',
      'grants',
      'maximumGrants',
      'maximumLifetimeSeconds',
    });
    final rawGrants = value['grants'];
    if (value['schemaVersion'] != 1 ||
        value['catalogVersion'] != 'larenor-mcp-tools-v1' ||
        value['maximumGrants'] != 128 ||
        value['maximumLifetimeSeconds'] != 3600 ||
        rawGrants is! List ||
        rawGrants.length > 128) {
      _invalid();
    }
    return ServerMcpGrantList._(
      List.unmodifiable(rawGrants.map(ServerMcpGrant.fromJson)),
    );
  }

  final List<ServerMcpGrant> grants;
}

final class ServerMcpIssuedGrant {
  const ServerMcpIssuedGrant(this.grant, this.accessToken);

  factory ServerMcpIssuedGrant.fromJson(Object? raw) {
    final value = _object(raw, {'grant', 'accessToken'});
    final token = value['accessToken'];
    if (token is! String || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      _invalid();
    }
    return ServerMcpIssuedGrant(ServerMcpGrant.fromJson(value['grant']), token);
  }

  final ServerMcpGrant grant;
  final String accessToken;
}
