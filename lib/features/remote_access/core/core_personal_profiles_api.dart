import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../data/remote_profiles.dart';
import 'core_personal_profiles.dart';

final class CorePersonalProfilesApi {
  CorePersonalProfilesApi(
    this._api,
    this._token,
    this._context, {
    required bool Function() current,
  }) : _isCurrent = current;

  final LarenorServerApi _api;
  final String _token;
  final ServerContext _context;
  final bool Function() _isCurrent;
  bool _retired = false;

  String get _path =>
      '/personal-profiles/${_context.coreId}/${_context.homeId}';

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

  Future<CorePersonalProfilesSnapshot> list() => _operation(() async {
    final body = await _api.request('GET', _path, token: _token);
    return CorePersonalProfilesSnapshot.fromJson(
      body,
      expectedContext: _context,
    );
  });

  Future<CorePersonalProfile> create(RemoteProfile desired) =>
      _operation(() async {
        final body = await _api.request(
          'POST',
          _path,
          token: _token,
          body: _fields(desired),
        );
        return _record(body, desired: desired, create: true);
      });

  Future<CorePersonalProfile> update(
    CorePersonalProfile target,
    RemoteProfile desired,
  ) => _operation(() async {
    _target(target);
    final before = target.profile;
    final changed =
        before.name != desired.name ||
        before.protocol != desired.protocol ||
        before.host != desired.host ||
        before.port != desired.port ||
        before.username != desired.username;
    if (changed && target.revision == 9223372036854775807) {
      throw const LarenorServerException('revision_conflict');
    }
    final body = await _api.request(
      'PATCH',
      '$_path/${target.id}',
      token: _token,
      body: {..._fields(desired), 'expectedRevision': target.revision},
    );
    final value = _record(body, expectedId: target.id, desired: desired);
    if (value.revision != target.revision + (changed ? 1 : 0)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  });

  Future<void> delete(CorePersonalProfile target) => _operation(() async {
    _target(target);
    final body = await _api.request(
      'DELETE',
      '$_path/${target.id}',
      token: _token,
      queryParameters: {'expectedRevision': '${target.revision}'},
      allowEmpty: true,
    );
    if (body != null) throw const LarenorServerException('invalid_response');
  });

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

  CorePersonalProfile _record(
    Map<String, dynamic>? body, {
    String? expectedId,
    required RemoteProfile desired,
    bool create = false,
  }) {
    if (body == null || body.length != 1 || !body.containsKey('profile')) {
      throw const LarenorServerException('invalid_response');
    }
    final value = CorePersonalProfile.fromJson(
      body['profile'],
      expectedContext: _context,
    );
    final actual = value.profile;
    if (expectedId != null && value.id != expectedId ||
        actual.name != desired.name ||
        actual.protocol != desired.protocol ||
        actual.host != desired.host ||
        actual.port != desired.port ||
        actual.username != desired.username ||
        create && value.revision != 1) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  void _target(CorePersonalProfile target) {
    if (target.context != _context) {
      throw const LarenorServerException('invalid_request');
    }
  }

  @override
  String toString() => 'CorePersonalProfilesApi(redacted)';
}
