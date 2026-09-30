import 'dart:math';

import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/irrigation_budget_models.dart';

abstract interface class IrrigationBudgetApi {
  Future<IrrigationBudgetSnapshot> load();
  void retire();
}

abstract interface class IrrigationControlApi {
  Future<IrrigationControlPreview> preview(IrrigationBudgetSnapshot snapshot);
  Future<IrrigationControlReceipt> confirm(IrrigationControlPreview preview);
  Future<IrrigationStopReceipt> stop(
    IrrigationBudgetSnapshot snapshot,
    List<String> zoneIds,
  );
}

final class CoreIrrigationBudgetApi
    implements IrrigationBudgetApi, IrrigationControlApi {
  CoreIrrigationBudgetApi({
    required this.account,
    required this.routeId,
    required this.sessionRevision,
    required this.routeRevision,
    required this.isCurrent,
  });

  final ServerAccountController account;
  final String routeId;
  final int sessionRevision, routeRevision;
  final bool Function() isCurrent;
  ServerSession? _session;
  bool _retired = false;

  ServerSession? get boundSession => _session;

  void _check() {
    var current = false;
    try {
      current = !_retired && isCurrent();
    } catch (_) {
      current = false;
    }
    if (current) return;
    retire();
    throw const LarenorServerException('cancelled');
  }

  @override
  void retire() {
    _retired = true;
    _session = null;
  }

  @override
  Future<IrrigationBudgetSnapshot> load() => account.withSession((
    api,
    session,
  ) async {
    _check();
    if (!session.user.canAdminister || session.context == null) {
      throw const LarenorServerException('forbidden');
    }
    _session ??= session;
    if (!identical(_session, session) || !identical(account.session, session)) {
      retire();
      throw const LarenorServerException('cancelled');
    }
    final response = _object(
      await api.request(
        'GET',
        '/admin/irrigation-budget',
        token: session.accessToken,
      ),
    );
    _check();
    if (!identical(_session, session) || !identical(account.session, session)) {
      retire();
      throw const LarenorServerException('cancelled');
    }
    _keys(response, const {'snapshot'});
    return _decode(_object(response['snapshot']), session);
  });

  Future<T> _post<T>(
    String path,
    Map<String, Object?> body,
    T Function(Map<String, dynamic>) decode,
  ) => account.withSession((api, session) async {
    _check();
    if (!session.user.canAdminister || session.context == null) {
      throw const LarenorServerException('forbidden');
    }
    _session ??= session;
    if (!identical(_session, session) || !identical(account.session, session)) {
      retire();
      throw const LarenorServerException('cancelled');
    }
    final response = _object(
      await api.request('POST', path, token: session.accessToken, body: body),
    );
    _check();
    if (!identical(_session, session) || !identical(account.session, session)) {
      retire();
      throw const LarenorServerException('cancelled');
    }
    return decode(response);
  });

  @override
  Future<IrrigationControlPreview> preview(IrrigationBudgetSnapshot snapshot) =>
      _post('/admin/irrigation-budget/preview', {
        'schemaVersion': 1,
        'requestId': _requestId(),
        'expectedPlanId': snapshot.planId,
        'expectedPolicyRevision': snapshot.authority.policyRevision,
        'expectedBudgetRevision': snapshot.authority.budgetRevision,
      }, _decodePreview);

  @override
  Future<IrrigationControlReceipt> confirm(IrrigationControlPreview preview) =>
      _post('/admin/irrigation-budget/confirm', {
        'schemaVersion': 1,
        'previewId': preview.previewId,
        'confirmToken': preview.confirmToken,
      }, _decodeReceipt);

  @override
  Future<IrrigationStopReceipt> stop(
    IrrigationBudgetSnapshot snapshot,
    List<String> zoneIds,
  ) => _post('/admin/irrigation-budget/stop', {
    'schemaVersion': 1,
    'requestId': _requestId(),
    'expectedPolicyRevision': snapshot.authority.policyRevision,
    'zoneIds': zoneIds,
  }, _decodeStopReceipt);

  static String _requestId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  IrrigationBudgetSnapshot _decode(
    Map<String, dynamic> raw,
    ServerSession session,
  ) {
    _keys(raw, const {
      'schemaVersion',
      'authority',
      'policyId',
      'policyRevision',
      'planId',
      'generatedAtMs',
      'forecastStatus',
      'rainMilliMm',
      'budget',
      'zones',
      'controlCapability',
      'commandEndpointAvailable',
    });
    if (_int(raw['schemaVersion']) != 1 ||
        raw['commandEndpointAvailable'] is! bool) {
      _invalid();
    }
    final authorityRaw = _object(raw['authority']);
    _keys(authorityRaw, const {
      'schemaVersion',
      'coreId',
      'homeId',
      'homeRevision',
      'accountId',
      'accountRevision',
      'sessionFamilyId',
      'role',
      'active',
      'canManageIrrigation',
    });
    if (_int(authorityRaw['schemaVersion']) != 1 ||
        authorityRaw['role'] != 'admin' ||
        authorityRaw['active'] != true ||
        authorityRaw['canManageIrrigation'] != true) {
      _invalid();
    }
    final context = session.context!;
    final policyRevision = _positive(raw['policyRevision']);
    final budget = _object(raw['budget']);
    _keys(budget, const {
      'revision',
      'dailyLimitMl',
      'usedMl',
      'plannedMl',
      'estimatedCostMicros',
    });
    final authority = IrrigationBudgetAuthority(
      coreId: _identity(authorityRaw['coreId']),
      homeId: _identity(authorityRaw['homeId']),
      accountId: _identity(authorityRaw['accountId']),
      sessionFamilyId: _identity(authorityRaw['sessionFamilyId']),
      policyId: _identity(raw['policyId']),
      routeId: _text(routeId, 128),
      homeRevision: _positive(authorityRaw['homeRevision']),
      accountRevision: _positive(authorityRaw['accountRevision']),
      policyRevision: policyRevision,
      budgetRevision: _positive(budget['revision']),
      clientSessionRevision: sessionRevision,
      routeRevision: routeRevision,
    );
    if (authority.coreId != context.coreId ||
        authority.homeId != context.homeId ||
        authority.accountId != session.user.id ||
        !authority.isBounded) {
      _invalid();
    }
    final rawZones = raw['zones'];
    if (rawZones is! List || rawZones.isEmpty || rawZones.length > 32) {
      _invalid();
    }
    final seen = <String>{};
    final zones = <IrrigationZoneBudget>[];
    for (final item in rawZones) {
      final zone = _object(item);
      _keys(zone, const {
        'zoneId',
        'zoneRevision',
        'areaName',
        'plantName',
        'moisturePermille',
        'soilReadingRevision',
        'status',
        'reason',
        'durationSeconds',
        'estimatedWaterMl',
      });
      final zoneId = _identity(zone['zoneId']);
      if (!seen.add(zoneId)) _invalid();
      zones.add(
        IrrigationZoneBudget(
          zoneId: zoneId,
          zoneRevision: _positive(zone['zoneRevision']),
          areaName: _text(zone['areaName'], 120),
          plantName: _text(zone['plantName'], 120),
          moisturePermille: _bounded(zone['moisturePermille'], 0, 1000),
          soilReadingRevision: _positive(zone['soilReadingRevision']),
          status: _oneOf(zone['status'], const {
            'planned',
            'deferred',
            'skipped',
            'blocked',
          }),
          reason: _oneOf(zone['reason'], const {
            'moisture_deficit',
            'manual_override',
            'rain_forecast',
            'moisture_sufficient',
            'budget_exhausted',
            'leak_detected',
            'freeze_risk',
            'wind_risk',
            'safety_stale',
            'soil_sensor_stale',
          }),
          durationSeconds: _bounded(zone['durationSeconds'], 0, 7200),
          estimatedWaterMl: _bounded(zone['estimatedWaterMl'], 0, 10000000000),
        ),
      );
    }
    final daily = _bounded(budget['dailyLimitMl'], 0, 10000000000);
    final used = _bounded(budget['usedMl'], 0, daily);
    final planned = _bounded(budget['plannedMl'], 0, daily - used);
    final capability = _oneOf(raw['controlCapability'], const {
      'read_only',
      'manual_required',
      'verified_control',
    });
    final commandAvailable = raw['commandEndpointAvailable']! as bool;
    if (commandAvailable != (capability == 'verified_control')) _invalid();
    return IrrigationBudgetSnapshot(
      authority: authority,
      planId: _identity(raw['planId']),
      generatedAtMs: _bounded(raw['generatedAtMs'], 0, 0x7fffffffffffffff),
      forecastStatus: _oneOf(raw['forecastStatus'], const {
        'available',
        'stale',
      }),
      rainMilliMm: _bounded(raw['rainMilliMm'], 0, 10000000),
      dailyLimitMl: daily,
      usedMl: used,
      plannedMl: planned,
      estimatedCostMicros: _bounded(
        budget['estimatedCostMicros'],
        0,
        0x7fffffffffffffff,
      ),
      controlCapability: capability,
      commandEndpointAvailable: commandAvailable,
      zones: List.unmodifiable(zones),
    );
  }

  IrrigationControlPreview _decodePreview(Map<String, dynamic> response) {
    _keys(response, const {'schemaVersion', 'preview'});
    if (_int(response['schemaVersion']) != 1) _invalid();
    final raw = _object(response['preview']);
    _keys(raw, const {
      'schemaVersion',
      'previewId',
      'confirmToken',
      'requestId',
      'planId',
      'policyRevision',
      'expiresAtMs',
      'commandCount',
    });
    if (_int(raw['schemaVersion']) != 1) _invalid();
    final token = _text(raw['confirmToken'], 43);
    if (token.length != 43 || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      _invalid();
    }
    return IrrigationControlPreview(
      previewId: _identity(raw['previewId']),
      confirmToken: token,
      requestId: _identity(raw['requestId']),
      planId: _identity(raw['planId']),
      policyRevision: _positive(raw['policyRevision']),
      expiresAtMs: _bounded(raw['expiresAtMs'], 0, 0x7fffffffffffffff),
      commandCount: _bounded(raw['commandCount'], 1, 32),
    );
  }

  IrrigationControlReceipt _decodeReceipt(Map<String, dynamic> response) {
    _keys(response, const {'schemaVersion', 'receipt'});
    if (_int(response['schemaVersion']) != 1) _invalid();
    final raw = _object(response['receipt']);
    _keys(raw, const {
      'schemaVersion',
      'requestId',
      'planId',
      'status',
      'results',
      'completedAtMs',
    });
    if (_int(raw['schemaVersion']) != 1) _invalid();
    final status = _oneOf(raw['status'], const {
      'applied',
      'partial',
      'failed',
      'unknown',
    });
    final results = _decodeResults(raw['results'], stop: false);
    final states = results.map((value) => value.status).toSet();
    final expected = states.length > 1
        ? 'partial'
        : states.single == 'applied'
        ? 'applied'
        : states.single;
    if (status != expected) _invalid();
    return IrrigationControlReceipt(
      requestId: _identity(raw['requestId']),
      planId: _identity(raw['planId']),
      status: status,
      completedAtMs: _bounded(raw['completedAtMs'], 0, 0x7fffffffffffffff),
      results: results,
    );
  }

  IrrigationStopReceipt _decodeStopReceipt(Map<String, dynamic> response) {
    _keys(response, const {'schemaVersion', 'receipt'});
    if (_int(response['schemaVersion']) != 1) _invalid();
    final raw = _object(response['receipt']);
    _keys(raw, const {
      'schemaVersion',
      'requestId',
      'status',
      'results',
      'completedAtMs',
    });
    if (_int(raw['schemaVersion']) != 1) _invalid();
    final status = _oneOf(raw['status'], const {
      'stopped',
      'partial',
      'failed',
      'unknown',
    });
    final results = _decodeResults(raw['results'], stop: true);
    final states = results.map((value) => value.status).toSet();
    final expected = states.length > 1
        ? 'partial'
        : states.single == 'stopped'
        ? 'stopped'
        : states.single;
    if (status != expected) _invalid();
    return IrrigationStopReceipt(
      requestId: _identity(raw['requestId']),
      status: status,
      completedAtMs: _bounded(raw['completedAtMs'], 0, 0x7fffffffffffffff),
      results: results,
    );
  }

  List<IrrigationCommandResult> _decodeResults(
    Object? value, {
    required bool stop,
  }) {
    if (value is! List || value.isEmpty || value.length > 32) _invalid();
    final seen = <String>{};
    return List.unmodifiable(
      value.map((item) {
        final raw = _object(item);
        _keys(raw, const {
          'schemaVersion',
          'commandId',
          'zoneId',
          'status',
          'code',
          'readback',
        });
        if (_int(raw['schemaVersion']) != 1) _invalid();
        final commandId = _identity(raw['commandId']);
        final zoneId = _identity(raw['zoneId']);
        if (!seen.add(zoneId)) _invalid();
        final readback = raw['readback'];
        _IrrigationReadbackEvidence? evidence;
        if (readback != null) {
          evidence = _validateReadback(
            _object(readback),
            stop: stop,
            commandId: commandId,
            zoneId: zoneId,
          );
        }
        final status = _oneOf(
          raw['status'],
          stop
              ? const {'stopped', 'failed', 'unknown'}
              : const {'applied', 'failed', 'unknown'},
        );
        final code = _oneOf(
          raw['code'],
          stop
              ? const {
                  'stopped',
                  'readback_mismatch',
                  'flow_still_active',
                  'worker_ack_unknown',
                }
              : const {
                  'applied',
                  'flow_not_verified',
                  'flow_out_of_bounds',
                  'readback_mismatch',
                  'worker_ack_unknown',
                  'cancelled_before_start',
                  'cancelled_safe_stop',
                  'safe_stop_failed',
                },
        );
        if ((status == 'applied') != (code == 'applied') ||
            (status == 'stopped') != (code == 'stopped') ||
            ((code == 'applied' || code == 'stopped') && readback == null) ||
            (code == 'worker_ack_unknown' && readback != null)) {
          _invalid();
        }
        return IrrigationCommandResult(
          zoneId: zoneId,
          status: status,
          code: code,
          deliveredMl: evidence?.deliveredMl,
          flowVerified: evidence?.flowVerified,
          flowActive: evidence?.flowActive,
        );
      }),
    );
  }

  _IrrigationReadbackEvidence _validateReadback(
    Map<String, dynamic> raw, {
    required bool stop,
    required String commandId,
    required String zoneId,
  }) {
    _keys(
      raw,
      stop
          ? const {
              'schemaVersion',
              'commandId',
              'zone',
              'stateRevision',
              'valveOpen',
              'flowActive',
              'observedAtMs',
            }
          : const {
              'schemaVersion',
              'commandId',
              'zone',
              'stateRevision',
              'valveOpen',
              'deliveredMl',
              'flowVerified',
              'observedAtMs',
            },
    );
    if (_int(raw['schemaVersion']) != 1 ||
        _identity(raw['commandId']) != commandId ||
        raw['valveOpen'] is! bool ||
        (stop && raw['flowActive'] is! bool) ||
        (!stop && raw['flowVerified'] is! bool)) {
      _invalid();
    }
    _positive(raw['stateRevision']);
    _bounded(raw['observedAtMs'], 0, 0x7fffffffffffffff);
    final deliveredMl = stop
        ? null
        : _bounded(raw['deliveredMl'], 0, 10000000000);
    final zone = _object(raw['zone']);
    _keys(zone, const {
      'schemaVersion',
      'coreId',
      'homeId',
      'zoneId',
      'zoneRevision',
      'areaId',
      'areaRevision',
      'valveServiceId',
      'valveServiceRevision',
      'valveBindingId',
      'valveBindingRevision',
      'flowMlPerMinute',
      'maxDurationSeconds',
    });
    if (_int(zone['schemaVersion']) != 1 ||
        _identity(zone['zoneId']) != zoneId) {
      _invalid();
    }
    for (final key in const [
      'coreId',
      'homeId',
      'areaId',
      'valveServiceId',
      'valveBindingId',
    ]) {
      _identity(zone[key]);
    }
    for (final key in const [
      'zoneRevision',
      'areaRevision',
      'valveServiceRevision',
      'valveBindingRevision',
    ]) {
      _positive(zone[key]);
    }
    _bounded(zone['flowMlPerMinute'], 1, 1000000);
    _bounded(zone['maxDurationSeconds'], 1, 7200);
    return _IrrigationReadbackEvidence(
      deliveredMl: deliveredMl,
      flowVerified: stop ? null : raw['flowVerified'] as bool,
      flowActive: stop ? raw['flowActive'] as bool : null,
    );
  }

  static Never _invalid() =>
      throw const LarenorServerException('invalid_response');
  static Map<String, dynamic> _object(Object? value) =>
      value is Map<String, dynamic> ? value : _invalid();
  static void _keys(Map<String, dynamic> value, Set<String> expected) {
    if (value.keys.toSet().difference(expected).isNotEmpty ||
        expected.difference(value.keys.toSet()).isNotEmpty) {
      _invalid();
    }
  }

  static int _int(Object? value) => value is int ? value : _invalid();
  static int _positive(Object? value) => _bounded(value, 1, 0x7fffffff);
  static int _bounded(Object? value, int min, int max) {
    final result = _int(value);
    return result >= min && result <= max ? result : _invalid();
  }

  static String _text(Object? value, int max) {
    if (value is! String ||
        value.isEmpty ||
        value.length > max ||
        value != value.trim()) {
      _invalid();
    }
    return value;
  }

  static String _identity(Object? value) {
    final result = _text(value, 32);
    return result.length == 32 && RegExp(r'^[0-9a-f]{32}$').hasMatch(result)
        ? result
        : _invalid();
  }

  static String _oneOf(Object? value, Set<String> allowed) {
    final result = _text(value, 64);
    return allowed.contains(result) ? result : _invalid();
  }
}

final class _IrrigationReadbackEvidence {
  const _IrrigationReadbackEvidence({
    required this.deliveredMl,
    required this.flowVerified,
    required this.flowActive,
  });

  final int? deliveredMl;
  final bool? flowVerified, flowActive;
}
