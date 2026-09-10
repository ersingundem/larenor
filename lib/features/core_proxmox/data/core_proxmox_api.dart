import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../../server/services/data/server_services_api.dart';
import '../../server/services/domain/server_service_models.dart';
import '../domain/core_proxmox_models.dart';

final class CoreProxmoxApi {
  CoreProxmoxApi(
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
      // A failed authority check grants no read or write capability.
    }
    retire();
    throw const LarenorServerException('cancelled');
  }

  Future<T> _operation<T>(Future<T> Function() action) async {
    _check();
    if (target.kind != HomeResourceKind.resource) {
      throw const LarenorServerException('invalid_request');
    }
    try {
      final result = await action();
      _check();
      return result;
    } catch (_) {
      _check();
      rethrow;
    }
  }

  Object? _envelope(Map<String, dynamic>? value, String key) {
    if (value == null || value.length != 1 || !value.containsKey(key)) {
      throw const LarenorServerException('invalid_response');
    }
    return value[key];
  }

  String get _scope => '${target.context.coreId}/${target.context.homeId}';
  String get _path => '/proxmox/$_scope/resources/${target.id}';
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
        value.kind != HomeResourceKind.resource ||
        value.revision < target.revision ||
        value.aclRevision < target.aclRevision) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  });

  Future<CoreProxmoxSnapshot> snapshot() => _operation(() async {
    final raw = await _transport.request('GET', '$_path/snapshot', token: _token);
    _check();
    return CoreProxmoxSnapshot.fromJson(
      _envelope(raw, 'snapshot'),
      target: target,
    );
  });

  Future<CoreProxmoxBinding?> binding() => _operation(() async {
    try {
      final raw = await _transport.request('GET', '$_admin/binding', token: _token);
      _check();
      return CoreProxmoxBinding.fromJson(
        _envelope(raw, 'binding'),
        target: target,
      );
    } on LarenorServerException catch (error) {
      _check();
      if (error.code == 'not_found') return null;
      rethrow;
    }
  });

  Future<List<ServerService>> services() => _operation(() async {
    final values = await ServerServicesApi(_transport, _token).list();
    _check();
    return List.unmodifiable(
      values.where((value) => value.kind == ServerServiceKind.proxmox),
    );
  });

  Future<CoreProxmoxPreview> preview({
    required ServerService service,
    required CoreProxmoxBinding? existing,
  }) => _operation(() async {
    if (service.kind != ServerServiceKind.proxmox ||
        existing?.revision == 9223372036854775807 ||
        existing != null &&
            (existing.target.id != target.id ||
                existing.target.context != target.context)) {
      throw const LarenorServerException('invalid_request');
    }
    final raw = await _transport.request(
      'POST',
      '$_admin/binding-preview',
      token: _token,
      body: {
        'serviceId': service.id,
        'expectedServiceRevision': service.revision,
        'expectedRevision': target.revision,
        'expectedAclRevision': target.aclRevision,
        'expectedBindingId': existing?.id,
      },
    );
    _check();
    final value = CoreProxmoxPreview.fromJson(
      _envelope(raw, 'preview'),
      target: target,
    );
    if (value.binding.serviceId != service.id ||
        value.binding.serviceRevision != service.revision ||
        value.binding.revision != (existing == null ? 1 : existing.revision + 1)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  });

  Future<CoreProxmoxBinding> confirm(CoreProxmoxPreview preview) =>
      _operation(() async {
        final raw = await _transport.request(
          'POST',
          '$_admin/binding-confirm',
          token: _token,
          body: {'previewId': preview.id},
        );
        _check();
        final value = CoreProxmoxBinding.fromJson(
          _envelope(raw, 'binding'),
          target: target,
        );
        if (!value.sameBinding(preview.binding)) {
          throw const LarenorServerException('invalid_response');
        }
        return value;
      });

  Future<void> cancel(CoreProxmoxPreview preview) => _operation(() async {
    final result = await _transport.request(
      'DELETE',
      '$_admin/binding-preview/${preview.id}',
      token: _token,
      allowEmpty: true,
    );
    if (result != null) throw const LarenorServerException('invalid_response');
  });
}
