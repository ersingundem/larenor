import '../../server/domain/server_models.dart';
import 'home_resource_models.dart';

enum HomeResourcePermission {
  none,
  readOnly,
  readWrite;

  Map<String, bool> toJson() => {
    'read': this != none,
    'write': this == readWrite,
  };
}

/// A versioned snapshot, not an authorization grant for the current actor.
final class HomeResourceGrants {
  HomeResourceGrants._(this.target, this.aclRevision, this.grants);
  factory HomeResourceGrants.fromJson(Object? raw, {required HomeResourceRecord target}) =>
      throw const LarenorServerException('invalid_response');

  final HomeResourceRecord target;
  final int aclRevision;
  final Map<String, HomeResourcePermission> grants;
  HomeResourcePermission permissionFor(String subjectId) => grants[subjectId] ?? HomeResourcePermission.none;
  HomeResourceGrants withUpdatedGrant(Object? raw, {required String subjectId,
      required HomeResourcePermission permission}) =>
      throw const LarenorServerException('invalid_response');
  @override
  String toString() => 'HomeResourceGrants';
}
