import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';

final class CoreGameStreamHost {
  CoreGameStreamHost._({
    required this.id,
    required this.revision,
    required this.pairingRevision,
    required this.name,
    required this.codecs,
    required this.maxWidth,
    required this.maxHeight,
    required this.maxFps,
  });

  factory CoreGameStreamHost.fromJson(
    Object? raw, {
    required ServerContext context,
  }) {
    final value = _map(raw);
    if (value.keys.toSet().difference({
          'schemaVersion',
          'ref',
          'revision',
          'name',
          'pairingRevision',
          'active',
          'codecs',
          'maxWidth',
          'maxHeight',
          'maxFps',
        }).isNotEmpty ||
        value.length != 10 ||
        value['schemaVersion'] != 1 ||
        value['active'] != true) {
      throw const LarenorServerException('invalid_response');
    }
    final ref = _map(value['ref']);
    if (ref.length != 5 ||
        ref['schemaVersion'] != 1 ||
        ref['coreId'] != context.coreId ||
        ref['homeId'] != context.homeId ||
        ref['kind'] != 'game_stream_host') {
      throw const LarenorServerException('invalid_response');
    }
    final codecs = value['codecs'];
    if (codecs is! List ||
        codecs.isEmpty ||
        codecs.length > 3 ||
        codecs.any(
          (item) => item is! String || !{'h264', 'hevc', 'av1'}.contains(item),
        ) ||
        codecs.toSet().length != codecs.length) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreGameStreamHost._(
      id: _id(ref['id']),
      revision: _revision(value['revision']),
      pairingRevision: _revision(value['pairingRevision']),
      name: _text(value['name'], 80),
      codecs: List.unmodifiable(codecs.cast<String>()),
      maxWidth: _integer(value['maxWidth'], 320, 8192),
      maxHeight: _integer(value['maxHeight'], 320, 8192),
      maxFps: _integer(value['maxFps'], 30, 240),
    );
  }

  final String id, name;
  final int revision, pairingRevision, maxWidth, maxHeight, maxFps;
  final List<String> codecs;
}

final class CoreGameStreamHosts {
  const CoreGameStreamHosts({
    required this.accountRevision,
    required this.hosts,
  });
  final int accountRevision;
  final List<CoreGameStreamHost> hosts;
}

final class CoreGameStreamLease {
  CoreGameStreamLease._({
    required this.id,
    required this.hostId,
    required this.revision,
    required this.expiresAt,
    required this.authority,
  });
  final String id, hostId;
  final int revision;
  final DateTime expiresAt;
  final Map<String, int> authority;

  factory CoreGameStreamLease.fromJson(
    Object? raw, {
    required CoreGameStreamHost host,
    required Map<String, int> expectedAuthority,
  }) {
    final value = _map(raw);
    if (value.length != 7 ||
        value['schemaVersion'] != 1 ||
        value['hostId'] != host.id ||
        value['state'] != 'open') {
      throw const LarenorServerException('invalid_response');
    }
    final authority = _map(value['authority']);
    if (authority.length != expectedAuthority.length ||
        expectedAuthority.entries.any(
          (entry) => authority[entry.key] != entry.value,
        )) {
      throw const LarenorServerException('invalid_response');
    }
    final expiry = value['expiresAt'];
    if (expiry is! num || !expiry.isFinite) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreGameStreamLease._(
      id: _id(value['id']),
      hostId: host.id,
      revision: _revision(value['revision']),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (expiry * 1000).round(),
        isUtc: true,
      ),
      authority: Map.unmodifiable(expectedAuthority),
    );
  }
}

final class CoreGameStreamCommand {
  CoreGameStreamCommand._({
    required this.id,
    required this.sessionId,
    required this.intent,
    required this.state,
    this.result,
    this.readbackRevision,
  });
  final String id, sessionId, intent, state;
  final String? result;
  final int? readbackRevision;

  factory CoreGameStreamCommand.fromJson(
    Object? raw, {
    required CoreGameStreamLease lease,
    required String intent,
  }) {
    final value = _map(raw);
    if (value.length != 9 ||
        value['schemaVersion'] != 1 ||
        value['sessionId'] != lease.id ||
        value['intent'] != intent ||
        !{
          'authorized',
          'verified',
          'unknown',
          'rejected',
        }.contains(value['state'])) {
      throw const LarenorServerException('invalid_response');
    }
    final revision = value['readbackRevision'];
    final expectedResult = switch (intent) {
      'wake' => 'hostAwake',
      'launch' => 'appRunning',
      'stream' => 'streaming',
      'stop' => 'stopped',
      _ => throw const LarenorServerException('invalid_response'),
    };
    final validOutcome = switch (value['state']) {
      'authorized' => value['result'] == null && revision == null,
      'verified' => value['result'] == expectedResult && revision != null,
      'rejected' => value['result'] == 'rejected' && revision == null,
      'unknown' => value['result'] == 'unknown' && revision == null,
      _ => false,
    };
    if (!validOutcome) {
      throw const LarenorServerException('invalid_response');
    }
    if (revision != null) _revision(revision);
    return CoreGameStreamCommand._(
      id: _id(value['id']),
      sessionId: lease.id,
      intent: intent,
      state: value['state']! as String,
      result: value['result'] as String?,
      readbackRevision: revision as int?,
    );
  }
}

final class CoreGameStreamApi {
  CoreGameStreamApi(
    this._api,
    this._session, {
    required bool Function() isCurrent,
  }) : _current = isCurrent;
  final LarenorServerApi _api;
  final ServerSession _session;
  final bool Function() _current;
  bool _retired = false;
  ServerContext get _context => _session.context!;
  String get _root => '/game-streaming/${_context.coreId}/${_context.homeId}';

  void retire() => _retired = true;
  void _check() {
    try {
      if (!_retired && _current()) return;
    } catch (_) {}
    _retired = true;
    throw const LarenorServerException('cancelled');
  }

  Future<T> _operation<T>(Future<T> Function() action) async {
    _check();
    try {
      final value = await action();
      _check();
      return value;
    } catch (_) {
      _check();
      rethrow;
    }
  }

  Future<CoreGameStreamHosts> hosts() => _operation(() async {
    final response = _map(
      await _api.request('GET', '$_root/hosts', token: _session.accessToken),
    );
    if (response.length != 4 || response['schemaVersion'] != 1) {
      throw const LarenorServerException('invalid_response');
    }
    final scope = _map(response['scope']);
    if (scope.length != 3 ||
        scope['schemaVersion'] != 1 ||
        scope['coreId'] != _context.coreId ||
        scope['homeId'] != _context.homeId ||
        response['hosts'] is! List) {
      throw const LarenorServerException('invalid_response');
    }
    final values = (response['hosts']! as List)
        .map((item) => CoreGameStreamHost.fromJson(item, context: _context))
        .toList();
    if (values.length > 64 ||
        values.map((item) => item.id).toSet().length != values.length) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreGameStreamHosts(
      accountRevision: _revision(response['accountRevision']),
      hosts: List.unmodifiable(values),
    );
  });

  Future<CoreGameStreamLease> open({
    required CoreGameStreamHost host,
    required int accountRevision,
    required int routeRevision,
    required int lifecycleRevision,
    required int displayRevision,
    required int networkRevision,
    required int policyRevision,
    required String requestKey,
    required DateTime expiresAt,
  }) => _operation(() async {
    final authority = <String, int>{
      'expectedHostRevision': host.revision,
      'expectedPairingRevision': host.pairingRevision,
      'accountRevision': accountRevision,
      'routeRevision': routeRevision,
      'lifecycleRevision': lifecycleRevision,
      'displayRevision': displayRevision,
      'networkRevision': networkRevision,
      'policyRevision': policyRevision,
    };
    final response = await _api.request(
      'POST',
      '$_root/hosts/${host.id}/sessions',
      token: _session.accessToken,
      body: {
        'schemaVersion': 1,
        'requestKey': requestKey,
        ...authority,
        'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch / 1000,
      },
    );
    _check();
    return CoreGameStreamLease.fromJson(
      response,
      host: host,
      expectedAuthority: authority,
    );
  });

  Future<CoreGameStreamCommand> authorize(
    CoreGameStreamLease lease, {
    required String requestKey,
    required String intent,
  }) => _operation(
    () async => CoreGameStreamCommand.fromJson(
      await _api.request(
        'POST',
        '$_root/sessions/${lease.id}/commands',
        token: _session.accessToken,
        body: {
          'schemaVersion': 1,
          'requestKey': requestKey,
          'expectedSessionRevision': lease.revision,
          'intent': intent,
        },
      ),
      lease: lease,
      intent: intent,
    ),
  );

  Future<CoreGameStreamCommand> complete(
    CoreGameStreamLease lease,
    CoreGameStreamCommand command, {
    required String state,
    required String result,
    int? readbackRevision,
  }) => _operation(
    () async => CoreGameStreamCommand.fromJson(
      await _api.request(
        'POST',
        '$_root/sessions/${lease.id}/commands/${command.id}/complete',
        token: _session.accessToken,
        body: {
          'schemaVersion': 1,
          'expectedSessionRevision': lease.revision,
          'state': state,
          'result': result,
          'readbackRevision': readbackRevision,
        },
      ),
      lease: lease,
      intent: command.intent,
    ),
  );
}

Map<String, dynamic> _map(Object? raw) {
  if (raw is! Map<String, dynamic>) {
    throw const LarenorServerException('invalid_response');
  }
  return raw;
}

String _id(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value)
    ? value
    : throw const LarenorServerException('invalid_response');
int _revision(Object? value) =>
    value is int && value >= 1 && value <= 9223372036854775807
    ? value
    : throw const LarenorServerException('invalid_response');
int _integer(Object? value, int min, int max) =>
    value is int && value >= min && value <= max
    ? value
    : throw const LarenorServerException('invalid_response');
String _text(Object? value, int max) =>
    value is String &&
        value.trim() == value &&
        value.isNotEmpty &&
        value.length <= max &&
        !value.contains(RegExp(r'[\x00-\x1f\x7f]'))
    ? value
    : throw const LarenorServerException('invalid_response');
