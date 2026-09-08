import '../../home_resources/domain/home_resource_models.dart';
import '../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');
Map _object(Object? value, Set<String> keys) {
  if (value is! Map || value.length != keys.length || !keys.every(value.containsKey)) _invalid();
  return value;
}
String _id(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value) || value.length != 32) _invalid();
  return value;
}
int _integer(Object? value, {int min = 1, int max = 9223372036854775807}) {
  if (value is! int || value < min || value > max) _invalid();
  return value;
}
void _schema(Object? value) { if (value is! int || value != 1) _invalid(); }
void _ref(Object? value, HomeResourceRecord target) {
  final ref = _object(value, {'schemaVersion', 'coreId', 'homeId', 'kind', 'id'});
  _schema(ref['schemaVersion']);
  if (target.kind != HomeResourceKind.resource || ref['kind'] != 'resource' || ref['id'] != target.id || ref['coreId'] != target.context.coreId || ref['homeId'] != target.context.homeId) _invalid();
}

enum CoreHaSwitchState { on, off, unavailable }

final class CoreHaProjection {
  const CoreHaProjection._(this.state);
  final CoreHaSwitchState state;
  bool get commandAvailable => false;
  factory CoreHaProjection.fromJson(Object? raw) {
    final value = _object(raw, {'kind', 'state', 'commandAvailable'});
    if (value['kind'] != 'switch' || value['commandAvailable'] is! bool || value['commandAvailable'] != false) _invalid();
    return CoreHaProjection._(switch (value['state']) {
      'on' => CoreHaSwitchState.on, 'off' => CoreHaSwitchState.off,
      'unavailable' => CoreHaSwitchState.unavailable, _ => _invalid(),
    });
  }
  @override
  String toString() => 'CoreHaProjection';
}

final class CoreHaSnapshot {
  const CoreHaSnapshot._(this.bindingId, this.bindingRevision,
      this.resourceRevision, this.aclRevision, this.serviceRevision,
      this.observedAt, this.remainingTtlMs, this.projection);
  final String bindingId;
  final int bindingRevision, resourceRevision, aclRevision, serviceRevision;
  final DateTime observedAt;
  final int remainingTtlMs;
  final CoreHaProjection projection;
  factory CoreHaSnapshot.fromJson(Object? raw, {required HomeResourceRecord target}) {
    final value = _object(raw, {'schemaVersion', 'ref', 'bindingId', 'bindingRevision', 'resourceRevision', 'aclRevision', 'serviceRevision', 'observedAt', 'remainingTtlMs', 'projection'});
    _schema(value['schemaVersion']); _ref(value['ref'], target);
    final text = value['observedAt'];
    if (text is! String || text.length > 40 || !RegExp(r'T.*(?:Z|\+00:00)$').hasMatch(text)) _invalid();
    final date = DateTime.tryParse(text);
    if (date == null || !date.isUtc) _invalid();
    return CoreHaSnapshot._(_id(value['bindingId']), _integer(value['bindingRevision']), _integer(value['resourceRevision'], min: target.revision), _integer(value['aclRevision'], min: target.aclRevision), _integer(value['serviceRevision']), date, _integer(value['remainingTtlMs'], min: 0, max: 5000), CoreHaProjection.fromJson(value['projection']));
  }
  @override
  String toString() => 'CoreHaSnapshot';
}

final class CoreHaBinding {
  const CoreHaBinding._(this.id, this.revision, this.target, this.serviceId,
      this.serviceRevision, this.entityId);
  final String id, serviceId, entityId;
  final int revision, serviceRevision;
  final HomeResourceRecord target;
  factory CoreHaBinding.fromJson(Object? raw, {required HomeResourceRecord target}) {
    final value = _object(raw, {'schemaVersion', 'id', 'revision', 'ref', 'serviceId', 'serviceRevision', 'entityId'});
    _schema(value['schemaVersion']); _ref(value['ref'], target);
    final entity = value['entityId'];
    if (entity is! String || !coreHaEntityId(entity)) _invalid();
    return CoreHaBinding._(_id(value['id']), _integer(value['revision']), target, _id(value['serviceId']), _integer(value['serviceRevision']), entity);
  }
  bool sameBinding(CoreHaBinding other) => id == other.id && revision == other.revision && target.context == other.target.context && target.id == other.target.id && serviceId == other.serviceId && serviceRevision == other.serviceRevision && entityId == other.entityId;
  @override
  String toString() => 'CoreHaBinding';
}

final class CoreHaPreview {
  const CoreHaPreview._(this.id, this.expiresInMs, this.binding, this.projection);
  final String id;
  final int expiresInMs;
  final CoreHaBinding binding;
  final CoreHaProjection projection;
  factory CoreHaPreview.fromJson(Object? raw, {required HomeResourceRecord target}) {
    final value = _object(raw, {'id', 'expiresInMs', 'binding', 'projection'});
    return CoreHaPreview._(_id(value['id']), _integer(value['expiresInMs'], max: 60000), CoreHaBinding.fromJson(value['binding'], target: target), CoreHaProjection.fromJson(value['projection']));
  }
  @override
  String toString() => 'CoreHaPreview';
}

bool coreHaEntityId(String value) => value.length <= 128 && RegExp(r'^switch\.[a-z0-9_]+$').hasMatch(value) && !value.endsWith('\n');
