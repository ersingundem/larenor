import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../../services/domain/server_service_models.dart';
import '../domain/server_component_egress_models.dart';

final class ServerComponentEgressApi {
  const ServerComponentEgressApi(this.api, this.token);

  final LarenorServerApi api;
  final String token;

  Future<ServerComponentEgressResponse> read(ServerService service) async {
    _expectedComponent(service);
    return _parse(
      await api.request(
        'GET',
        '/admin/services/${service.id}/outbound-policy',
        token: token,
      ),
      service,
    );
  }

  Future<ServerComponentEgressResponse> replace(
    ServerService service,
    ServerComponentEgressResponse current, {
    ServerComponentEgressGrant? grant,
  }) async {
    _validate(current, service);
    final List<ServerComponentEgressGrant> expectedGrants = grant == null
        ? const []
        : [grant];
    final value = _parse(
      await api.request(
        'PUT',
        '/admin/services/${service.id}/outbound-policy',
        token: token,
        body: {
          'expectedRevision': current.policy.revision,
          'expectedServiceRevision': service.revision,
          'grants': expectedGrants.map((value) => value.toJson()).toList(),
        },
      ),
      service,
    );
    if (value.policy.revision != current.policy.revision + 1 ||
        !_grantListsEqual(value.policy.grants, expectedGrants)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  ServerComponentEgressResponse _parse(
    Map<String, dynamic>? json,
    ServerService service,
  ) {
    final value = ServerComponentEgressResponse.fromJson(serverObject(json));
    _validate(value, service);
    return value;
  }

  void _validate(ServerComponentEgressResponse value, ServerService service) {
    final expected = _expectedComponent(service);
    if (value.policy.serviceId != service.id ||
        value.policy.serviceRevision != service.revision ||
        value.policy.component != expected) {
      throw const LarenorServerException('invalid_response');
    }
  }

  ServerComponentEgressComponent _expectedComponent(ServerService service) =>
      switch (service.kind) {
        ServerServiceKind.homeAssistant =>
          ServerComponentEgressComponent.homeAssistantProbe,
        ServerServiceKind.proxmox =>
          ServerComponentEgressComponent.proxmoxCommandWorker,
        ServerServiceKind.keenetic =>
          ServerComponentEgressComponent.keeneticCommandWorker,
        _ => throw const LarenorServerException('invalid_request'),
      };

  @override
  String toString() => 'ServerComponentEgressApi';
}

bool _grantListsEqual(
  List<ServerComponentEgressGrant> left,
  List<ServerComponentEgressGrant> right,
) =>
    left.length == right.length &&
    List.generate(
      left.length,
      (index) => left[index] == right[index],
    ).every((value) => value);
