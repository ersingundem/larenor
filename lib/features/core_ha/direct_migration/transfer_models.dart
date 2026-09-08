import '../../home_resources/domain/home_resource_models.dart';
import '../../server/domain/server_models.dart';
import '../../server/services/domain/server_service_models.dart';
import '../domain/core_ha_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');
Map<String, dynamic> _object(Object? raw, Set<String> keys) {
  if (raw is! Map<String, dynamic> || raw.length != keys.length || !keys.every(raw.containsKey)) _invalid();
  return raw;
}
bool transferId(String value) => value.length == 32 && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);
String _id(Object? raw) {
  if (raw is! String || !transferId(raw)) _invalid();
  return raw;
}
int _integer(Object? raw, {int max = 9223372036854775807}) {
  if (raw is! int || raw < 1 || raw > max) _invalid();
  return raw;
}

/// Public archival metadata only. There is deliberately no credential field.
final class CoreHaTransferReceipt {
  CoreHaTransferReceipt._(this.requestId, this.service, this.binding);
  final String requestId;
  final ServerService service;
  final CoreHaBinding binding;
  factory CoreHaTransferReceipt.fromJson(Object? raw, {required HomeResourceRecord target, required String requestId}) {
    final value = _object(raw, {'schemaVersion','requestId','status','ref','resourceRevision','aclRevision','service','binding'});
    if (value['schemaVersion'] is! int || value['schemaVersion'] != 1 || value['status'] != 'committed') _invalid();
    return _parse(value, target, requestId);
  }
  static CoreHaTransferReceipt _parse(Map<String, dynamic> value, HomeResourceRecord target, String requestId) {
    if (_id(value['requestId']) != requestId ||
        _integer(value['resourceRevision']) != target.revision ||
        _integer(value['aclRevision']) != target.aclRevision) _invalid();
    final ref = _object(value['ref'], {'schemaVersion','coreId','homeId','kind','id'});
    if (ref['schemaVersion'] is! int || ref['schemaVersion'] != 1 ||
        target.kind != HomeResourceKind.resource || ref['kind'] != 'resource' ||
        ref['coreId'] != target.context.coreId || ref['homeId'] != target.context.homeId || ref['id'] != target.id) _invalid();
    final service = ServerService.fromJson(serverObject(value['service']));
    final binding = CoreHaBinding.fromJson(value['binding'], target: target);
    if (service.kind != ServerServiceKind.homeAssistant || service.revision != 1 ||
        service.credentialKeys.length != 1 || service.credentialKeys.single != 'token' ||
        service.verification.state != ServerServiceVerificationState.never ||
        binding.serviceId != service.id || binding.serviceRevision != 1 || binding.revision != 1) _invalid();
    return CoreHaTransferReceipt._(requestId, service, binding);
  }
  bool sameCommit(CoreHaTransferReceipt other) => requestId == other.requestId &&
      binding.sameBinding(other.binding) && service.id == other.service.id &&
      service.name == other.service.name && service.baseUrl == other.service.baseUrl;
  @override String toString() => 'CoreHaTransferReceipt';
}

final class CoreHaTransferPreview {
  CoreHaTransferPreview._(this.id, this.expiresInMs, this.commit, this.projection);
  final String id;
  final int expiresInMs;
  final CoreHaTransferReceipt commit;
  String get requestId => commit.requestId;
  final CoreHaProjection projection;
  factory CoreHaTransferPreview.fromJson(Object? raw, {required HomeResourceRecord target, required String requestId}) {
    final value = _object(raw, {'id','requestId','expiresInMs','ref','resourceRevision','aclRevision','service','binding','projection'});
    final projection = CoreHaProjection.fromJson(value['projection']);
    if (projection.commandAvailable) _invalid();
    return CoreHaTransferPreview._(_id(value['id']), _integer(value['expiresInMs'], max: 60000),
        CoreHaTransferReceipt._parse(value, target, requestId), projection);
  }
  @override String toString() => 'CoreHaTransferPreview';
}
