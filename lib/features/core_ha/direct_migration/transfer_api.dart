import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../../server/services/domain/server_service_models.dart';
import '../domain/core_ha_models.dart';
import 'transfer_models.dart';

/// Borrows the bounded Core transport. Retiring it never closes account auth.
final class CoreHaTransferApi {
  CoreHaTransferApi(this.transport, this.token, this.target, {required this.isCurrent});
  final LarenorServerApi transport;
  final String token;
  final HomeResourceRecord target;
  final bool Function() isCurrent;
  bool _retired = false;
  void retire() => _retired = true;
  void _check() {
    try { if (!_retired && isCurrent()) return; } catch (_) { /* No authority. */ }
    retire();
    throw const LarenorServerException('cancelled');
  }
  Future<T> _run<T>(Future<T> Function() operation) async {
    _check();
    if (target.kind != HomeResourceKind.resource) throw const LarenorServerException('invalid_request');
    try { final value = await operation(); _check(); return value; }
    catch (_) { _check(); rethrow; }
  }
  String get _path => '/admin/home-assistant/${target.context.coreId}/${target.context.homeId}/resources/${target.id}/direct-migration';
  Object? _envelope(Map<String, dynamic>? raw, String key) {
    if (raw == null || raw.length != 1 || !raw.containsKey(key)) throw const LarenorServerException('invalid_response');
    return raw[key];
  }
  Map<String, dynamic> _input({required String requestId, required String name,
    required String baseUrl, required String credential, required String entityId}) {
    if (!transferId(requestId) || !validServiceName(name) || !coreHaEntityId(entityId) ||
        credential.isEmpty || credential.length > 2048 || credential.codeUnits.any((u) => u < 33 || u > 126)) {
      throw const LarenorServerException('invalid_request');
    }
    return {'requestId': requestId, 'name': name, 'baseUrl': serviceEndpoint(baseUrl), 'token': credential,
      'entityId': entityId, 'expectedRevision': target.revision, 'expectedAclRevision': target.aclRevision};
  }
  Future<CoreHaTransferPreview> preview({required String requestId, required String name,
    required String baseUrl, required String credential, required String entityId}) => _run(() async {
    final input = _input(requestId: requestId, name: name, baseUrl: baseUrl, credential: credential, entityId: entityId);
    final raw = await transport.request('POST', '$_path/preview', token: token, body: input);
    _check();
    final value = CoreHaTransferPreview.fromJson(_envelope(raw, 'preview'), target: target, requestId: requestId);
    if (value.commit.service.name != input['name'] || value.commit.service.baseUrl != input['baseUrl'] || value.commit.binding.entityId != entityId) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  });
  Future<CoreHaTransferReceipt> confirm(CoreHaTransferPreview preview, {required String name,
    required String baseUrl, required String credential, required String entityId}) => _run(() async {
    final input = _input(requestId: preview.requestId, name: name, baseUrl: baseUrl, credential: credential, entityId: entityId);
    if (preview.commit.binding.target.context != target.context || preview.commit.binding.target.id != target.id ||
        preview.commit.service.name != input['name'] || preview.commit.service.baseUrl != input['baseUrl'] || preview.commit.binding.entityId != entityId) {
      throw const LarenorServerException('invalid_request');
    }
    final raw = await transport.request('POST', '$_path/confirm', token: token, body: {...input, 'previewId': preview.id});
    _check();
    final receipt = CoreHaTransferReceipt.fromJson(_envelope(raw, 'receipt'), target: target, requestId: preview.requestId);
    if (!receipt.sameCommit(preview.commit)) throw const LarenorServerException('invalid_response');
    return receipt;
  });
  Future<CoreHaTransferReceipt?> result(CoreHaTransferPreview preview) => _run(() async {
    try {
      final raw = await transport.request('GET', '$_path/results/${preview.requestId}', token: token);
      _check();
      final receipt = CoreHaTransferReceipt.fromJson(_envelope(raw, 'receipt'), target: target, requestId: preview.requestId);
      if (!receipt.sameCommit(preview.commit)) throw const LarenorServerException('invalid_response');
      return receipt;
    } on LarenorServerException catch (error) {
      _check();
      if (error.code == 'not_found') return null;
      rethrow;
    }
  });
  Future<void> cancel(CoreHaTransferPreview preview) => _run(() async {
    if (preview.commit.binding.target.context != target.context || preview.commit.binding.target.id != target.id) throw const LarenorServerException('invalid_request');
    final raw = await transport.request('DELETE', '$_path/preview/${preview.id}', token: token, allowEmpty: true);
    _check();
    if (raw != null) throw const LarenorServerException('invalid_response');
  });
  @override String toString() => 'CoreHaTransferApi';
}
