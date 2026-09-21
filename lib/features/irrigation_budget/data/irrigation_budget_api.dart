import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/irrigation_budget_models.dart';

abstract interface class IrrigationBudgetApi {
  Future<IrrigationBudgetSnapshot> load();
  void retire();
}

final class CoreIrrigationBudgetApi implements IrrigationBudgetApi {
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
        raw['commandEndpointAvailable'] != false) {
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
    if (rawZones is! List || rawZones.isEmpty || rawZones.length > 32)
      _invalid();
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
      controlCapability: _oneOf(raw['controlCapability'], const {
        'read_only',
        'manual_required',
      }),
      commandEndpointAvailable: false,
      zones: List.unmodifiable(zones),
    );
  }

  static Never _invalid() =>
      throw const LarenorServerException('invalid_response');
  static Map<String, dynamic> _object(Object? value) =>
      value is Map<String, dynamic> ? value : _invalid();
  static void _keys(Map<String, dynamic> value, Set<String> expected) {
    if (value.keys.toSet().difference(expected).isNotEmpty ||
        expected.difference(value.keys.toSet()).isNotEmpty)
      _invalid();
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
        value != value.trim())
      _invalid();
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
