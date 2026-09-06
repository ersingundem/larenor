import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/home_resource_models.dart';
import '../domain/home_resource_mutations.dart';

/// Metadata transport. Server authorization is required for every call.
final class HomeResourceAdminApi {
  const HomeResourceAdminApi(
    LarenorServerApi api,
    String token,
    ServerContext context,
  ) : _api = api,
      _token = token,
      _context = context;
  final LarenorServerApi _api;
  final String _token;
  final ServerContext _context;

  String get _path =>
      '/admin/home-resources/${_context.coreId}/${_context.homeId}';

  void _target(HomeResourceRecord target) {
    // Identity/kind/revisions are already strict immutable read-model values.
    // A write ACL is not proof of admin role; the Server checks current auth.
    if (target.context != _context) {
      throw const LarenorServerException('invalid_request');
    }
  }

  HomeResourceRecord _record(
    Map<String, dynamic>? body,
    HomeResourceKind kind,
    HomeResourceMetadata metadata, {
    String? id,
  }) {
    if (body == null || body.length != 1 || !body.containsKey('record')) {
      throw const LarenorServerException('invalid_response');
    }
    final value = HomeResourceRecord.fromJson(
      body['record'],
      expectedContext: _context,
    );
    if (value.kind != kind ||
        (id != null && value.id != id) ||
        value.label != metadata.label ||
        value.order != metadata.order ||
        !value.canWrite) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  Future<HomeResourceRecord> create({
    required HomeResourceKind kind,
    required String label,
    required int order,
  }) async {
    final metadata = HomeResourceMetadata(label: label, order: order);
    final body = await _api.request(
      'POST',
      _path,
      token: _token,
      body: {'kind': kind.name, ...metadata.toJson()},
    );
    final value = _record(body, kind, metadata);
    if (value.revision != 1 || value.aclRevision != 1) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  Future<HomeResourceRecord> update(
    HomeResourceRecord target, {
    required String label,
    required int order,
  }) async {
    _target(target);
    final metadata = HomeResourceMetadata(label: label, order: order);
    final body = await _api.request(
      'PATCH',
      '$_path/${target.id}',
      token: _token,
      body: {
        'expectedRevision': target.revision,
        'expectedAclRevision': target.aclRevision,
        ...metadata.toJson(),
      },
    );
    final value = _record(body, target.kind, metadata, id: target.id);
    final changed =
        metadata.label != target.label || metadata.order != target.order;
    if (value.aclRevision != target.aclRevision ||
        (changed
            ? target.revision == 9223372036854775807 ||
                  value.revision != target.revision + 1
            : value.revision != target.revision)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  Future<void> delete(HomeResourceRecord target) async {
    _target(target);
    final result = await _api.request(
      'DELETE',
      '$_path/${target.id}',
      token: _token,
      queryParameters: {
        'expectedRevision': '${target.revision}',
        'expectedAclRevision': '${target.aclRevision}',
      },
      allowEmpty: true,
    );
    // The shared decoder returns null only for actual 204 with an empty body.
    if (result != null) throw const LarenorServerException('invalid_response');
  }

  @override
  String toString() => 'HomeResourceAdminApi';
}
