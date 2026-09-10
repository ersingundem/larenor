import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../../server/services/data/server_services_api.dart';
import '../../server/services/domain/server_service_models.dart';
import '../domain/core_ha_activity_models.dart';
import '../domain/core_ha_models.dart';

final class CoreHaApi {
  CoreHaApi(
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
      /* No authority. */
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

  Object? _envelope(Map<String, dynamic>? json, String key) {
    if (json == null || json.length != 1 || !json.containsKey(key)) {
      throw const LarenorServerException('invalid_response');
    }
    return json[key];
  }

  String get _scope => '${target.context.coreId}/${target.context.homeId}';
  String get _path => '/home-assistant/$_scope/resources/${target.id}';
  String get _admin => '/admin$_path';
  Future<HomeResourceRecord> resource() => _operation(() async {
    final raw = await _transport.request(
      'GET',
      '/home-resources/$_scope/${target.id}',
      token: _token,
    );
    _check();
    final result = HomeResourceRecord.fromJson(
      _envelope(raw, 'record'),
      expectedContext: target.context,
    );
    if (result.id != target.id ||
        result.kind != target.kind ||
        result.revision < target.revision ||
        result.aclRevision < target.aclRevision) {
      throw const LarenorServerException('invalid_response');
    }
    return result;
  });
  Future<CoreHaSnapshot> snapshot() => _operation(() async {
    final raw = await _transport.request(
      'GET',
      '$_path/snapshot',
      token: _token,
    );
    _check();
    return CoreHaSnapshot.fromJson(_envelope(raw, 'snapshot'), target: target);
  });
  Future<CoreHaCommandReceipt> command({
    required String requestId,
    required CoreHaCommandAction action,
    required CoreHaSnapshot snapshot,
  }) => _operation(() async {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId) ||
        !target.canWrite ||
        snapshot.projection.kind != 'switch' ||
        !snapshot.projection.commandAvailable ||
        snapshot.resourceRevision != target.revision ||
        snapshot.aclRevision != target.aclRevision) {
      throw const LarenorServerException('invalid_request');
    }
    final actionValue = switch (action) {
      CoreHaCommandAction.turnOn => 'turn_on',
      CoreHaCommandAction.turnOff => 'turn_off',
    };
    final raw = await _transport.request(
      'POST',
      '$_path/commands',
      token: _token,
      body: {
        'schemaVersion': 1,
        'requestId': requestId,
        'action': actionValue,
        'expectedBindingRevision': snapshot.bindingRevision,
        'expectedResourceRevision': snapshot.resourceRevision,
        'expectedAclRevision': snapshot.aclRevision,
      },
    );
    _check();
    final receipt = CoreHaCommandReceipt.fromJson(
      _envelope(raw, 'receipt'),
      target: target,
    );
    if (receipt.requestId != requestId ||
        receipt.action != action ||
        receipt.bindingId != snapshot.bindingId ||
        receipt.bindingRevision != snapshot.bindingRevision) {
      throw const LarenorServerException('invalid_response');
    }
    return receipt;
  });
  Future<CoreHaCommandReceipt> commandResult(String requestId) =>
      _operation(() async {
        if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
          throw const LarenorServerException('invalid_request');
        }
        final raw = await _transport.request(
          'GET',
          '$_path/commands/$requestId',
          token: _token,
        );
        _check();
        final receipt = CoreHaCommandReceipt.fromJson(
          _envelope(raw, 'receipt'),
          target: target,
        );
        if (receipt.requestId != requestId) {
          throw const LarenorServerException('invalid_response');
        }
        return receipt;
      });
  Future<CoreHaHistoryPage> history({String? before, int limit = 25}) =>
      _operation(() async {
        if (limit < 1 ||
            limit > CoreHaHistoryPage.maximumPageSize ||
            before != null && !RegExp(r'^[0-9a-f]{32}$').hasMatch(before)) {
          throw const LarenorServerException('invalid_request');
        }
        final raw = await _transport.request(
          'GET',
          '$_path/history',
          token: _token,
          queryParameters: {
            if (before != null) 'before': before,
            'limit': '$limit',
          },
        );
        _check();
        return CoreHaHistoryPage.fromJson(raw, target: target);
      });
  Future<CoreHaHistoryVerification> verifyHistory({
    String? checkpoint,
  }) => _operation(() async {
    if (checkpoint != null &&
        (checkpoint.isEmpty ||
            checkpoint.length > 512 ||
            checkpoint.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e))) {
      throw const LarenorServerException('invalid_request');
    }
    final raw = await _transport.request(
      'GET',
      '/admin/home-assistant/$_scope/history/verification',
      token: _token,
      queryParameters: checkpoint == null ? null : {'checkpoint': checkpoint},
    );
    _check();
    return CoreHaHistoryVerification.fromJson(
      _envelope(raw, 'verification'),
      expectedContext: target.context,
      expectedComparison: checkpoint != null,
    );
  });
  Future<CoreHaBinding?> binding() => _operation(() async {
    try {
      final raw = await _transport.request(
        'GET',
        '$_admin/binding',
        token: _token,
      );
      _check();
      return CoreHaBinding.fromJson(_envelope(raw, 'binding'), target: target);
    } on LarenorServerException catch (error) {
      _check();
      if (error.code == 'not_found') return null;
      rethrow;
    }
  });
  Future<List<ServerService>> services() => _operation(() async {
    final services = await ServerServicesApi(_transport, _token).list();
    _check();
    return List.unmodifiable(
      services.where((s) => s.kind == ServerServiceKind.homeAssistant),
    );
  });
  void _bindingTarget(CoreHaBinding binding) {
    if (binding.target.id != target.id ||
        binding.target.context != target.context) {
      throw const LarenorServerException('invalid_request');
    }
  }

  Future<CoreHaPreview> preview({
    required ServerService service,
    required String entityId,
    required CoreHaBinding? existing,
  }) => _operation(() async {
    if (service.kind != ServerServiceKind.homeAssistant ||
        !coreHaEntityId(entityId) ||
        existing?.revision == 9223372036854775807) {
      throw const LarenorServerException('invalid_request');
    }
    if (existing != null) _bindingTarget(existing);
    final raw = await _transport.request(
      'POST',
      '$_admin/binding-preview',
      token: _token,
      body: {
        'serviceId': service.id,
        'expectedServiceRevision': service.revision,
        'expectedRevision': target.revision,
        'expectedAclRevision': target.aclRevision,
        'entityId': entityId,
        'expectedBindingId': existing?.id,
      },
    );
    _check();
    final value = CoreHaPreview.fromJson(
          _envelope(raw, 'preview'),
          target: target,
        ),
        b = value.binding;
    if (b.serviceId != service.id ||
        b.serviceRevision != service.revision ||
        b.entityId != entityId ||
        b.revision != (existing?.revision ?? 0) + 1 ||
        b.id == existing?.id) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  });
  Future<CoreHaBinding> confirm(CoreHaPreview preview) => _operation(() async {
    _bindingTarget(preview.binding);
    final raw = await _transport.request(
      'POST',
      '$_admin/binding-confirm',
      token: _token,
      body: {'previewId': preview.id},
    );
    _check();
    final binding = CoreHaBinding.fromJson(
      _envelope(raw, 'binding'),
      target: target,
    );
    if (!binding.sameBinding(preview.binding)) {
      throw const LarenorServerException('invalid_response');
    }
    return binding;
  });
  Future<void> cancel(CoreHaPreview preview) => _operation(() async {
    _bindingTarget(preview.binding);
    final raw = await _transport.request(
      'DELETE',
      '$_admin/binding-preview/${preview.id}',
      token: _token,
      allowEmpty: true,
    );
    _check();
    if (raw != null) throw const LarenorServerException('invalid_response');
  });
  @override
  String toString() => 'CoreHaApi';
}
