import '../../../home_resources/domain/home_resource_models.dart';
import '../../../server/data/larenor_server_api.dart';
import '../../../server/domain/server_models.dart';
import '../../../server/services/data/server_services_api.dart';
import '../../../server/services/domain/server_service_models.dart';
import '../domain/core_keenetic_models.dart';

final class CoreKeeneticApi {
  CoreKeeneticApi(
    this._transport,
    this._token,
    this.target, {
    required bool Function() isCurrent,
  }) : _current = isCurrent;
  final LarenorServerApi _transport;
  final String _token;
  final HomeResourceRecord target;
  final bool Function() _current;
  bool _retired = false;
  void retire() => _retired = true;
  void _check() {
    try {
      if (!_retired && _current()) return;
    } catch (_) {
      /* no authority */
    }
    _retired = true;
    throw const LarenorServerException('cancelled');
  }

  Future<T> _operation<T>(Future<T> Function() action) async {
    _check();
    if (target.kind != HomeResourceKind.resource) {
      throw const LarenorServerException('invalid_request');
    }
    try {
      final value = await action();
      _check();
      return value;
    } catch (_) {
      _check();
      rethrow;
    }
  }

  Object? _envelope(Map<String, dynamic>? raw, String key) {
    if (raw == null || raw.length != 1 || !raw.containsKey(key)) {
      throw const LarenorServerException('invalid_response');
    }
    return raw[key];
  }

  String get _scope => '${target.context.coreId}/${target.context.homeId}';
  String get _path => '/keenetic/$_scope/resources/${target.id}';
  String get _admin => '/admin$_path';
  Future<HomeResourceRecord> resource() => _operation(() async {
    final raw = await _transport.request(
      'GET',
      '/home-resources/$_scope/${target.id}',
      token: _token,
    );
    _check();
    final value = HomeResourceRecord.fromJson(
      _envelope(raw, 'record'),
      expectedContext: target.context,
    );
    if (value.id != target.id ||
        value.kind != target.kind ||
        value.revision < target.revision ||
        value.aclRevision < target.aclRevision) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  });
  Future<CoreKeeneticSnapshot> snapshot() => _operation(
    () async => CoreKeeneticSnapshot.fromJson(
      _envelope(
        await _transport.request('GET', '$_path/snapshot', token: _token),
        'snapshot',
      ),
      target: target,
    ),
  );
  Future<CoreKeeneticDetailsPage> details({
    int limit = 100,
    String? after,
    String? expectedSnapshot,
  }) => _operation(() async {
    if (limit < 1 ||
        limit > 100 ||
        (after == null) != (expectedSnapshot == null) ||
        after != null &&
            (!RegExp(r'^[0-9a-f]{64}$').hasMatch(after) ||
                !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedSnapshot!))) {
      throw const LarenorServerException('invalid_request');
    }
    final query = <String, String>{'limit': '$limit'};
    if (after != null) {
      query['after'] = after;
      query['expectedSnapshot'] = expectedSnapshot!;
    }
    return CoreKeeneticDetailsPage.fromJson(
      await _transport.request(
        'GET',
        '$_path/details',
        token: _token,
        queryParameters: query,
      ),
    );
  });
  Future<CoreKeeneticTopologySnapshot> topology() => _operation(
    () async => CoreKeeneticTopologySnapshot.fromJson(
      _envelope(
        await _transport.request('GET', '$_path/topology', token: _token),
        'topology',
      ),
      target: target,
    ),
  );
  Future<CoreKeeneticBinding?> binding() => _operation(() async {
    try {
      return CoreKeeneticBinding.fromJson(
        _envelope(
          await _transport.request('GET', '$_admin/binding', token: _token),
          'binding',
        ),
        target: target,
      );
    } on LarenorServerException catch (e) {
      _check();
      if (e.code == 'not_found') return null;
      rethrow;
    }
  });
  Future<List<ServerService>> services() => _operation(() async {
    final values = await ServerServicesApi(_transport, _token).list();
    _check();
    return List.unmodifiable(
      values.where((s) => s.kind == ServerServiceKind.keenetic),
    );
  });
  Future<CoreKeeneticPreview> preview({
    required ServerService service,
    required CoreKeeneticBinding? existing,
  }) => _operation(() async {
    if (service.kind != ServerServiceKind.keenetic ||
        existing?.revision == 0x7fffffffffffffff) {
      throw const LarenorServerException('invalid_request');
    }
    final raw = await _transport.request(
      'POST',
      '$_admin/binding-preview',
      token: _token,
      body: {
        'serviceId': service.id,
        'expectedServiceRevision': service.revision,
        'expectedResourceRevision': target.revision,
        'expectedAclRevision': target.aclRevision,
        'expectedBindingId': existing?.id,
      },
    );
    _check();
    final value = CoreKeeneticPreview.fromJson(
      _envelope(raw, 'preview'),
      target: target,
    );
    if (value.binding.serviceId != service.id ||
        value.binding.serviceRevision != service.revision ||
        value.binding.revision != (existing?.revision ?? 0) + 1 ||
        value.binding.id == existing?.id) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  });
  Future<CoreKeeneticBinding> confirm(CoreKeeneticPreview preview) =>
      _operation(() async {
        final value = CoreKeeneticBinding.fromJson(
          _envelope(
            await _transport.request(
              'POST',
              '$_admin/binding-confirm',
              token: _token,
              body: {'previewId': preview.id},
            ),
            'binding',
          ),
          target: target,
        );
        if (!value.sameBinding(preview.binding)) {
          throw const LarenorServerException('invalid_response');
        }
        return value;
      });
  Future<void> cancel(CoreKeeneticPreview preview) => _operation(() async {
    final raw = await _transport.request(
      'DELETE',
      '$_admin/binding-preview/${preview.id}',
      token: _token,
      allowEmpty: true,
    );
    _check();
    if (raw != null) throw const LarenorServerException('invalid_response');
  });
}
