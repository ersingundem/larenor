import 'dart:math';

import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../data/remote_profiles.dart';
import 'core_personal_profiles.dart';

final class CorePersonalProfilesApi {
  CorePersonalProfilesApi(
    this._api,
    this._token,
    this._context,
    this._accountId, {
    required bool Function() current,
    String Function()? requestId,
  }) : _isCurrent = current,
       _requestId = requestId ?? _randomId;

  final LarenorServerApi _api;
  final String _token, _accountId;
  final ServerContext _context;
  final bool Function() _isCurrent;
  final String Function() _requestId;
  bool _retired = false;

  String get _path =>
      '/core-remote-profiles/${_context.coreId}/${_context.homeId}';

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  String _nextRequestId() {
    final value = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_request');
    }
    return value;
  }

  void retire() => _retired = true;

  void _check() {
    try {
      if (!_retired && _isCurrent()) return;
    } catch (_) {
      // A broken owner callback grants no authority.
    }
    _retired = true;
    throw const LarenorServerException('cancelled');
  }

  Future<T> _operation<T>(Future<T> Function() action) async {
    _check();
    try {
      final result = await action();
      _check();
      return result;
    } catch (_) {
      _check();
      rethrow;
    }
  }

  Future<CorePersonalProfilesSnapshot> list({
    CorePersonalProfileAuthority? expectedAuthority,
  }) => _operation(() async {
    final body = await _api.request('GET', _path, token: _token);
    return CorePersonalProfilesSnapshot.fromJson(
      body,
      expectedContext: _context,
      expectedAccountId: _accountId,
      expectedSessionFamilyId: expectedAuthority?.sessionFamilyId,
      expectedAccountRevision: expectedAuthority?.accountRevision,
    );
  });

  Future<CorePersonalProfileMutation> create(
    RemoteProfile desired,
    CorePersonalProfilesSnapshot before,
  ) => _operation(() async {
    _snapshot(before);
    final body = await _api.request(
      'POST',
      _path,
      token: _token,
      body: {
        ..._fields(desired),
        'requestId': _nextRequestId(),
        'expectedAccountRevision': before.authority.accountRevision,
        'expectedCollectionRevision': before.collectionRevision,
      },
    );
    return _record(body, before: before, desired: desired, delta: 1);
  });

  Future<CorePersonalProfileMutation> update(
    CorePersonalProfile target,
    RemoteProfile desired,
    CorePersonalProfilesSnapshot before,
  ) => _operation(() async {
    _target(target, before);
    final changed = !_sameFields(target.profile, desired);
    if (changed && target.revision == 9223372036854775807) {
      throw const LarenorServerException('revision_conflict');
    }
    final body = await _api.request(
      'PATCH',
      '$_path/${target.id}',
      token: _token,
      body: {
        ..._fields(desired),
        'requestId': _nextRequestId(),
        'expectedAccountRevision': before.authority.accountRevision,
        'expectedCollectionRevision': before.collectionRevision,
        'expectedRevision': target.revision,
      },
    );
    final result = _record(
      body,
      before: before,
      desired: desired,
      delta: changed ? 1 : 0,
      expectedId: target.id,
    );
    if (result.profile?.revision != target.revision + (changed ? 1 : 0)) {
      throw const LarenorServerException('invalid_response');
    }
    return result;
  });

  Future<CorePersonalProfileMutation> delete(
    CorePersonalProfile target,
    CorePersonalProfilesSnapshot before,
  ) => _operation(() async {
    _target(target, before);
    final body = await _api.request(
      'DELETE',
      '$_path/${target.id}',
      token: _token,
      queryParameters: {
        'requestId': _nextRequestId(),
        'expectedRevision': '${target.revision}',
        'expectedAccountRevision': '${before.authority.accountRevision}',
        'expectedCollectionRevision': '${before.collectionRevision}',
      },
    );
    if (body == null ||
        body.length != 2 ||
        !body.containsKey('authority') ||
        !body.containsKey('deletion')) {
      throw const LarenorServerException('invalid_response');
    }
    final authority = _authority(body['authority'], before, delta: 1);
    final deletion = serverObject(body['deletion']);
    const deletionKeys = {'ref', 'deletedRevision'};
    if (deletion.length != deletionKeys.length ||
        !deletion.keys.toSet().containsAll(deletionKeys) ||
        deletion['deletedRevision'] != target.revision) {
      throw const LarenorServerException('invalid_response');
    }
    final ref = serverObject(deletion['ref']);
    const refKeys = {
      'schemaVersion',
      'coreId',
      'homeId',
      'kind',
      'id',
      'accountId',
    };
    if (ref.length != refKeys.length ||
        !ref.keys.toSet().containsAll(refKeys) ||
        ref['schemaVersion'] != 1 ||
        ref['coreId'] != _context.coreId ||
        ref['homeId'] != _context.homeId ||
        ref['kind'] != 'coreRemoteProfile' ||
        ref['id'] != target.id ||
        ref['accountId'] != _accountId) {
      throw const LarenorServerException('invalid_response');
    }
    return CorePersonalProfileMutation(
      authority: authority,
      deletedId: target.id,
      deletedRevision: target.revision,
    );
  });

  CorePersonalProfileMutation _record(
    Map<String, dynamic>? body, {
    required CorePersonalProfilesSnapshot before,
    required RemoteProfile desired,
    required int delta,
    String? expectedId,
  }) {
    if (body == null ||
        body.length != 2 ||
        !body.containsKey('authority') ||
        !body.containsKey('profile')) {
      throw const LarenorServerException('invalid_response');
    }
    final authority = _authority(body['authority'], before, delta: delta);
    final value = CorePersonalProfile.fromJson(
      body['profile'],
      expectedContext: _context,
      expectedAccountId: _accountId,
    );
    if (expectedId != null && value.id != expectedId ||
        !_sameFields(value.profile, desired) ||
        expectedId == null && value.revision != 1) {
      throw const LarenorServerException('invalid_response');
    }
    return CorePersonalProfileMutation(authority: authority, profile: value);
  }

  CorePersonalProfileAuthority _authority(
    Object? input,
    CorePersonalProfilesSnapshot before, {
    required int delta,
  }) {
    if (before.collectionRevision > 9223372036854775807 - delta) {
      throw const LarenorServerException('revision_conflict');
    }
    final value = CorePersonalProfileAuthority.fromJson(
      input,
      expectedContext: _context,
      expectedAccountId: _accountId,
      expectedSessionFamilyId: before.authority.sessionFamilyId,
      expectedAccountRevision: before.authority.accountRevision,
    );
    if (value.collectionRevision != before.collectionRevision + delta) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  void _snapshot(CorePersonalProfilesSnapshot value) {
    if (value.context != _context || value.authority.accountId != _accountId) {
      throw const LarenorServerException('invalid_request');
    }
  }

  void _target(
    CorePersonalProfile target,
    CorePersonalProfilesSnapshot before,
  ) {
    _snapshot(before);
    if (target.context != _context ||
        target.accountId != _accountId ||
        !before.profiles.any(
          (value) => value.id == target.id && value.revision == target.revision,
        )) {
      throw const LarenorServerException('invalid_request');
    }
  }

  Map<String, Object> _fields(RemoteProfile value) {
    value.toJson();
    return {
      'label': value.name,
      'protocol': value.protocol.name,
      'host': value.host,
      'port': value.port,
      'username': value.username,
    };
  }

  static bool _sameFields(RemoteProfile left, RemoteProfile right) =>
      left.name == right.name &&
      left.protocol == right.protocol &&
      left.host == right.host &&
      left.port == right.port &&
      left.username == right.username;

  @override
  String toString() => 'CorePersonalProfilesApi(redacted)';
}
