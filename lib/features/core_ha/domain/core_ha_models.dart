import '../../home_resources/domain/home_resource_models.dart';

enum CoreHaSwitchState { on, off, unavailable }

final class CoreHaProjection {
  const CoreHaProjection._(this.state);
  final CoreHaSwitchState state;
  bool get commandAvailable => false;
  factory CoreHaProjection.fromJson(Object? raw) => throw UnimplementedError();
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
  factory CoreHaSnapshot.fromJson(Object? raw, {required HomeResourceRecord target}) => throw UnimplementedError();
  @override
  String toString() => 'CoreHaSnapshot';
}

final class CoreHaBinding {
  const CoreHaBinding._(this.id, this.revision, this.target, this.serviceId,
      this.serviceRevision, this.entityId);
  final String id, serviceId, entityId;
  final int revision, serviceRevision;
  final HomeResourceRecord target;
  factory CoreHaBinding.fromJson(Object? raw, {required HomeResourceRecord target}) => throw UnimplementedError();
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
  factory CoreHaPreview.fromJson(Object? raw, {required HomeResourceRecord target}) => throw UnimplementedError();
  @override
  String toString() => 'CoreHaPreview';
}

bool coreHaEntityId(String value) => false;
