import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_service_models.dart';

class ServerServicesApi {
  const ServerServicesApi(this.api, this.token);
  final LarenorServerApi api;
  final String token;

  Future<List<ServerService>> list() async {
    final json = await api.request('GET', '/admin/services', token: token);
    final raw = json?['services'];
    if (json?.length != 1 || raw is! List || raw.length > 128) {
      throw const LarenorServerException('invalid_response');
    }
    final items = raw
        .map((value) => ServerService.fromJson(serverObject(value)))
        .toList();
    if (items.map((value) => value.id).toSet().length != items.length) {
      throw const LarenorServerException('invalid_response');
    }
    return List.unmodifiable(items);
  }

  Future<ServerService> create({
    required String name,
    required ServerServiceKind kind,
    required String baseUrl,
    required Map<String, String> credentials,
  }) {
    _validate(name, credentials);
    return _record(
      api.request(
        'POST',
        '/admin/services',
        token: token,
        body: {
          'name': name,
          'kind': kind.wireName,
          'baseUrl': serviceEndpoint(baseUrl),
          'credentials': Map<String, String>.of(credentials),
        },
      ),
      expectedKind: kind,
    );
  }

  Future<ServerService> update(
    ServerService service, {
    required String name,
    required String baseUrl,
    Map<String, String>? credentials,
  }) async {
    _validate(name, credentials);
    final endpoint = serviceEndpoint(baseUrl);
    if (credentials == null && endpoint != service.baseUrl) {
      throw const LarenorServerException('service_endpoint_credentials');
    }
    return _record(
      api.request(
        'PATCH',
        '/admin/services/${service.id}',
        token: token,
        body: {
          'expectedRevision': service.revision,
          'name': name,
          'baseUrl': endpoint,
          if (credentials != null)
            'credentials': Map<String, String>.of(credentials),
        },
      ),
      previous: service,
      allowsRevisionIncrement: true,
    );
  }

  Future<ServerService> check(ServerService service) => _record(
    api.request(
      'POST',
      '/admin/services/${service.id}/check',
      token: token,
      body: {'expectedRevision': service.revision},
    ),
    previous: service,
  );

  Future<void> forget(ServerService service) async {
    await api.request(
      'DELETE',
      '/admin/services/${service.id}',
      token: token,
      queryParameters: {'expectedRevision': '${service.revision}'},
      allowEmpty: true,
    );
  }

  void _validate(String name, Map<String, String>? credentials) {
    if (!validServiceName(name) ||
        (credentials != null && !validServiceCredentials(credentials))) {
      throw const LarenorServerException('invalid_request');
    }
  }

  Future<ServerService> _record(
    Future<Map<String, dynamic>?> pending, {
    ServerService? previous,
    ServerServiceKind? expectedKind,
    bool allowsRevisionIncrement = false,
  }) async {
    final json = await pending;
    if (json?.length != 1 || !json!.containsKey('service')) {
      throw const LarenorServerException('invalid_response');
    }
    final record = ServerService.fromJson(serverObject(json['service']));
    if ((expectedKind != null && record.kind != expectedKind) ||
        (previous != null &&
            (record.id != previous.id ||
                record.kind != previous.kind ||
                record.revision < previous.revision ||
                record.revision - previous.revision >
                    (allowsRevisionIncrement ? 1 : 0)))) {
      throw const LarenorServerException('invalid_response');
    }
    return record;
  }

  @override
  String toString() => 'ServerServicesApi';
}
