import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/camera_visual_sensor_models.dart';
import 'camera_visual_sensor_api.dart';

const _safeInteger = 9007199254740991;
Never _invalid() => throw const LarenorServerException('invalid_response');
String _id(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value)
    ? value
    : _invalid();
String _name(Object? value) =>
    value is String && RegExp(r'^[A-Za-z0-9_]{1,80}$').hasMatch(value)
    ? value
    : _invalid();
int _revision(Object? value, {bool zero = false}) =>
    value is int && value >= (zero ? 0 : 1) && value <= _safeInteger
    ? value
    : _invalid();
Map<String, Object?> _object(Object? value, Set<String> keys) {
  final result = serverObject(value);
  if (result.length != keys.length || !result.keys.toSet().containsAll(keys)) {
    _invalid();
  }
  return result;
}

List<Object?> _list(Object? value, int limit) =>
    value is List && value.length <= limit ? value : _invalid();

final class VisualSourceCamera {
  const VisualSourceCamera(this.id, this.name);
  final String id, name;
}

final class VisualSourceBinding {
  const VisualSourceBinding(
    this.ruleId,
    this.revision,
    this.cameraId,
    this.model,
    this.label,
    this.confidenceBps,
    this.holdMs,
    this.clearMs,
    this.retentionMs,
  );
  final String ruleId, cameraId, model, label;
  final int revision, confidenceBps, holdMs, clearMs, retentionMs;
}

final class VisualSourceCatalog {
  const VisualSourceCatalog(
    this.sourceRevision,
    this.cameras,
    this.bindings,
    this.decoderAvailable,
  );
  final int sourceRevision;
  final List<VisualSourceCamera> cameras;
  final List<VisualSourceBinding> bindings;
  final bool decoderAvailable;
}

final class VisualSourceModel {
  const VisualSourceModel(this.name, this.revision, this.labels);
  final String name;
  final int revision;
  final List<String> labels;
}

abstract interface class VisualSourceGateway {
  Future<VisualSourceCatalog> load();
  Future<List<VisualSourceModel>> models(String cameraId, int sourceRevision);
  Future<CameraVisualSensor> save({
    required String ruleId,
    required int revision,
    required String cameraId,
    required String model,
    required String label,
    required int confidenceBps,
    required int holdMs,
    required int clearMs,
    required int retentionMs,
  });
  void retire();
}

final class AccountVisualSourceApi implements VisualSourceGateway {
  AccountVisualSourceApi({
    required ServerAccountController account,
    required bool Function() isCurrent,
  }) : _account = account,
       _current = isCurrent,
       _generation = account.generation,
       _session = account.session;
  final ServerAccountController _account;
  final bool Function() _current;
  final int _generation;
  final ServerSession? _session;
  bool _retired = false;
  void _check(ServerSession session) {
    var current = false;
    try {
      current = _current();
    } catch (_) {
      current = false;
    }
    if (_retired ||
        !current ||
        !_account.isCurrent(_generation) ||
        !identical(session, _session) ||
        !identical(_account.session, session) ||
        session.context == null ||
        !session.user.canAdminister) {
      retire();
      throw const LarenorServerException('cancelled');
    }
  }

  String _root(ServerSession session) =>
      '/camera-visual-sensors/${session.context!.coreId}/${session.context!.homeId}';
  @override
  Future<VisualSourceCatalog> load() =>
      _account.withSession((api, session) async {
        _check(session);
        final body = _object(
          await api.request(
            'GET',
            '${_root(session)}/sources',
            token: session.accessToken,
          ),
          {
            'schemaVersion',
            'cameraSourceRevision',
            'cameras',
            'bindings',
            'trainingRequirement',
            'frameDecoderAvailable',
          },
        );
        _check(session);
        if (body['schemaVersion'] != 1 ||
            body['frameDecoderAvailable'] is! bool ||
            body['trainingRequirement'] !=
                'Frigate 0.17: AVX+AVX2; configure and train in Frigate') {
          _invalid();
        }
        final cameras = _list(body['cameras'], 512)
            .map((raw) {
              final value = _object(raw, {'id', 'name'});
              final name = value['name'];
              if (name is! String ||
                  name.trim().isEmpty ||
                  name.length > 120 ||
                  name.runes.any((r) => r < 32 || (r >= 127 && r <= 159))) {
                _invalid();
              }
              return VisualSourceCamera(_id(value['id']), name);
            })
            .toList(growable: false);
        final bindings = _list(body['bindings'], 64)
            .map((raw) {
              final value = _object(raw, {
                'ruleId',
                'revision',
                'cameraId',
                'modelName',
                'label',
                'minimumConfidenceBps',
                'holdForMs',
                'clearAfterMs',
                'evidenceRetentionMs',
              });
              int bounded(String key, int min, int max) {
                final v = value[key];
                return v is int && v >= min && v <= max ? v : _invalid();
              }

              return VisualSourceBinding(
                _id(value['ruleId']),
                _revision(value['revision']),
                _id(value['cameraId']),
                _name(value['modelName']),
                _name(value['label']),
                bounded('minimumConfidenceBps', 1, 10000),
                bounded('holdForMs', 0, 60000),
                bounded('clearAfterMs', 0, 300000),
                bounded('evidenceRetentionMs', 1000, 300000),
              );
            })
            .toList(growable: false);
        if (cameras.map((c) => c.id).toSet().length != cameras.length ||
            bindings.map((b) => b.ruleId).toSet().length != bindings.length) {
          _invalid();
        }
        return VisualSourceCatalog(
          _revision(body['cameraSourceRevision'], zero: true),
          List.unmodifiable(cameras),
          List.unmodifiable(bindings),
          body['frameDecoderAvailable']! as bool,
        );
      });
  @override
  Future<List<VisualSourceModel>> models(String cameraId, int sourceRevision) =>
      _account.withSession((api, session) async {
        _check(session);
        _id(cameraId);
        _revision(sourceRevision);
        final body = _object(
          await api.request(
            'GET',
            '${_root(session)}/sources/candidates/$cameraId',
            token: session.accessToken,
          ),
          {'schemaVersion', 'cameraId', 'cameraSourceRevision', 'models'},
        );
        _check(session);
        if (body['schemaVersion'] != 1 ||
            body['cameraId'] != cameraId ||
            body['cameraSourceRevision'] != sourceRevision) {
          _invalid();
        }
        final models = _list(body['models'], 16)
            .map((raw) {
              final value = _object(raw, {'name', 'revision', 'labels'});
              final labels = _list(
                value['labels'],
                64,
              ).map(_name).toList(growable: false);
              if (labels.length < 2 || labels.toSet().length != labels.length) {
                _invalid();
              }
              return VisualSourceModel(
                _name(value['name']),
                _revision(value['revision']),
                List.unmodifiable(labels),
              );
            })
            .toList(growable: false);
        if (models.map((m) => m.name).toSet().length != models.length) {
          _invalid();
        }
        return List.unmodifiable(models);
      });
  @override
  Future<CameraVisualSensor> save({
    required String ruleId,
    required int revision,
    required String cameraId,
    required String model,
    required String label,
    required int confidenceBps,
    required int holdMs,
    required int clearMs,
    required int retentionMs,
  }) => _account.withSession((api, session) async {
    _check(session);
    _id(ruleId);
    _id(cameraId);
    _name(model);
    _name(label);
    _revision(revision, zero: true);
    if (confidenceBps < 1 ||
        confidenceBps > 10000 ||
        holdMs < 0 ||
        holdMs > 60000 ||
        clearMs < 0 ||
        clearMs > 300000 ||
        retentionMs < 1000 ||
        retentionMs > 300000) {
      _invalid();
    }
    final body = _object(
      await api.request(
        'PUT',
        '${_root(session)}/sources/$ruleId',
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'expectedRevision': revision,
          'cameraId': cameraId,
          'modelName': model,
          'label': label,
          'minimumConfidenceBps': confidenceBps,
          'holdForMs': holdMs,
          'clearAfterMs': clearMs,
          'evidenceRetentionMs': retentionMs,
        },
      ),
      {'schemaVersion', 'rule'},
    );
    _check(session);
    if (body['schemaVersion'] != 2) _invalid();
    final parser = CameraVisualSensorApi(
      api,
      session,
      isCurrent: () => !_retired && _current(),
    );
    try {
      final sensor = parser.parseConfiguredRule(body['rule']);
      if (sensor.ruleId != ruleId ||
          sensor.ruleRevision != revision + 1 ||
          sensor.cameraId != cameraId ||
          sensor.label != label ||
          sensor.state != VisualSensorState.unknown) {
        _invalid();
      }
      return sensor;
    } finally {
      parser.retire();
    }
  });
  @override
  void retire() => _retired = true;
}
