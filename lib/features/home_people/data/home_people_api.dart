import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/home_person_models.dart';

/// Profile metadata only. The Server checks current read/admin authorization.
///
/// The owner must bind [isCurrent] to its captured session, generation and scope.
/// Retirement rejects late results; it cannot undo an already dispatched write.
/// No automatic retries, credentials storage, provider or UI are introduced here.
final class HomePeopleApi {
  HomePeopleApi(
    this._api,
    this._token,
    this._context, {
    required this._isCurrent,
  });

  final LarenorServerApi _api;
  final String _token;
  final ServerContext _context;
  final bool Function() _isCurrent;
  bool _retired = false;

  void retire() => _retired = true;

  void _check() {
    try {
      if (!_retired && _isCurrent()) return;
    } catch (_) {
      // A failed owner check grants no access and exposes no local exception.
    }
    _retired = true;
    throw const LarenorServerException('cancelled');
  }

  Future<T> _operation<T>(Future<T> Function() action) async {
    _check();
    try {
      final value = await action();
      _check();
      return value;
    } catch (_) {
      // In particular, an old 401 must not reach a current account's handler.
      _check();
      rethrow;
    }
  }

  String get _path => '/home-people/${_context.coreId}/${_context.homeId}';
  String get _admin => '/admin$_path';
  static bool _identity(String value) => HomePersonGrants.isSubjectId(value);

  void _target(HomePersonRecord target) {
    if (target.context != _context) {
      throw const LarenorServerException('invalid_request');
    }
  }

  HomePersonRecord _record(Map<String, dynamic>? body, {String? id}) {
    if (body == null || body.length != 1 || !body.containsKey('person')) {
      throw const LarenorServerException('invalid_response');
    }
    final value = HomePersonRecord.fromJson(
      body['person'],
      expectedContext: _context,
    );
    if (id != null && value.id != id) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  void _metadata(HomePersonRecord record, HomePersonMetadata desired) {
    if (record.label != desired.label ||
        record.order != desired.order ||
        !record.canWrite) {
      throw const LarenorServerException('invalid_response');
    }
  }

  Future<HomePeoplePage> list({
    String? after,
    String? snapshot,
    int limit = HomePeoplePage.pageSize,
  }) => _operation(() async {
    if (limit < 1 ||
        limit > 100 ||
        after != null && (!_identity(after) || snapshot == null) ||
        snapshot != null &&
            (snapshot.length != 64 ||
                !RegExp(r'^[0-9a-f]{64}$').hasMatch(snapshot))) {
      throw const LarenorServerException('invalid_request');
    }
    final body = await _api.request(
      'GET',
      _path,
      token: _token,
      queryParameters: {
        if (limit != HomePeoplePage.pageSize) 'limit': '$limit',
        'after': ?after,
        'expectedSnapshot': ?snapshot,
      },
    );
    _check();
    return HomePeoplePage.fromJson(
      body,
      expectedContext: _context,
      after: after,
      expectedSnapshot: snapshot,
      limit: limit,
    );
  });

  Future<HomePersonRecord> get(String id) => _operation(() async {
    if (!_identity(id)) throw const LarenorServerException('invalid_request');
    final body = await _api.request('GET', '$_path/$id', token: _token);
    _check();
    return _record(body, id: id);
  });

  Future<HomePersonRecord> create({
    required String label,
    required int order,
  }) => _operation(() async {
    final desired = HomePersonMetadata(label: label, order: order);
    final body = await _api.request(
      'POST',
      _admin,
      token: _token,
      body: desired.toJson(),
    );
    _check();
    final value = _record(body);
    _metadata(value, desired);
    if (value.revision != 1 || value.aclRevision != 1) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  });

  Future<HomePersonRecord> update(
    HomePersonRecord target, {
    required String label,
    required int order,
  }) => _operation(() async {
    _target(target);
    final desired = HomePersonMetadata(label: label, order: order);
    final changed =
        desired.label != target.label || desired.order != target.order;
    if (changed && target.revision == HomePersonGrants.maximumRevision) {
      throw const LarenorServerException('revision_conflict');
    }
    final body = await _api.request(
      'PATCH',
      '$_admin/${target.id}',
      token: _token,
      body: {
        'expectedRevision': target.revision,
        'expectedAclRevision': target.aclRevision,
        ...desired.toJson(),
      },
    );
    _check();
    final value = _record(body, id: target.id);
    _metadata(value, desired);
    if (value.aclRevision != target.aclRevision ||
        value.revision != target.revision + (changed ? 1 : 0)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  });

  Future<void> delete(HomePersonRecord target) => _operation(() async {
    _target(target);
    final body = await _api.request(
      'DELETE',
      '$_admin/${target.id}',
      token: _token,
      queryParameters: {
        'expectedRevision': '${target.revision}',
        'expectedAclRevision': '${target.aclRevision}',
      },
      allowEmpty: true,
    );
    _check();
    if (body != null) throw const LarenorServerException('invalid_response');
  });

  Future<HomePersonGrants> grants(HomePersonRecord target) =>
      _operation(() async {
        _target(target);
        final body = await _api.request(
          'GET',
          '$_admin/${target.id}/grants',
          token: _token,
        );
        _check();
        return HomePersonGrants.fromJson(body, target: target);
      });

  Future<HomePersonGrants> setGrant(
    HomePersonGrants snapshot, {
    required String subjectId,
    required HomePersonPermission permission,
  }) => _operation(() async {
    _target(snapshot.target);
    if (!_identity(subjectId)) {
      throw const LarenorServerException('invalid_request');
    }
    final before = snapshot.permissionFor(subjectId);
    if (before != permission &&
        snapshot.aclRevision == HomePersonGrants.maximumRevision) {
      throw const LarenorServerException('revision_conflict');
    }
    if (before == HomePersonPermission.none &&
        permission != HomePersonPermission.none &&
        snapshot.grants.length == HomePersonGrants.maximumGrants) {
      throw const LarenorServerException('invalid_request');
    }
    final body = await _api.request(
      'PUT',
      '$_admin/${snapshot.target.id}/grants/$subjectId',
      token: _token,
      body: {
        'expectedAclRevision': snapshot.aclRevision,
        'permissions': permission.toJson(),
      },
    );
    _check();
    return snapshot.withUpdatedGrant(
      body,
      subjectId: subjectId,
      permission: permission,
    );
  });

  @override
  String toString() => 'HomePeopleApi';
}
