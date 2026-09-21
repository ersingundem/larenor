import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/ev_charging_models.dart';

final _id = RegExp(r'^[0-9a-f]{32}$');
final _digest = RegExp(r'^[0-9a-f]{64}$');

final class EvChargingApi implements EvChargingGateway {
  EvChargingApi(this._api, this._session, {required bool Function() isCurrent})
    : _current = isCurrent;
  final LarenorServerApi _api;
  final ServerSession _session;
  final bool Function() _current;
  bool _retired = false;
  ServerContext get _context => _session.context!;
  String get _root => '/ev-charging/${_context.coreId}/${_context.homeId}';

  void _check() {
    if (!_retired && _session.context != null && _current()) return;
    _retired = true;
    throw const LarenorServerException('cancelled');
  }

  Future<T> _run<T>(Future<T> Function() action) async {
    _check();
    try {
      final value = await action();
      _check();
      return value;
    } catch (_) {
      _check();
      rethrow;
    }
  }

  @override
  Future<EvChargeCapability> capability() => _run(() async {
    final value = serverObject(
      await _api.request(
        'GET',
        '$_root/capability',
        token: _session.accessToken,
      ),
    );
    _exact(value, const {
      'schemaVersion',
      'coreId',
      'homeId',
      'state',
      'providerKind',
      'canPlan',
      'canControl',
      'reason',
      'chargers',
    });
    if (value['schemaVersion'] != 1 ||
        value['coreId'] != _context.coreId ||
        value['homeId'] != _context.homeId) {
      throw const LarenorServerException('invalid_response');
    }
    final state = _enum(EvCapabilityState.values, value['state']);
    final rawChargers = value['chargers'];
    if (rawChargers is! List || rawChargers.length > 16) {
      throw const LarenorServerException('invalid_response');
    }
    final chargers = rawChargers.map(_charger).toList(growable: false);
    final canPlan = value['canPlan'], canControl = value['canControl'];
    final provider = value['providerKind'], reason = value['reason'];
    if (canPlan is! bool ||
        canControl is! bool ||
        provider is! String ||
        !const {'ocpp', 'vehicle_api', 'manual', 'none'}.contains(provider) ||
        reason is! String ||
        chargers.map((item) => item.id).toSet().length != chargers.length ||
        (state != EvCapabilityState.ready &&
            (canPlan || canControl || chargers.isNotEmpty)) ||
        (canPlan && chargers.isEmpty) ||
        (canControl && !canPlan)) {
      throw const LarenorServerException('invalid_response');
    }
    return EvChargeCapability(
      coreId: _context.coreId,
      homeId: _context.homeId,
      state: state,
      providerKind: provider,
      canPlan: canPlan,
      canControl: canControl,
      reason: reason,
      chargers: List.unmodifiable(chargers),
    );
  });

  EvChargerCapability _charger(Object? raw) {
    final value = serverObject(raw);
    _exact(value, const {
      'schemaVersion',
      'chargerId',
      'label',
      'chargerRevision',
      'scheduleRevision',
      'tariffRevision',
      'powerBudgetRevision',
      'currentSoc',
      'batteryCapacityWh',
      'maxCurrentAmp',
    });
    final label = value['label'];
    if (value['schemaVersion'] != 1 ||
        !_identity(value['chargerId']) ||
        label is! String ||
        label.trim() != label ||
        label.isEmpty ||
        label.length > 80 ||
        !_safeText(label)) {
      throw const LarenorServerException('invalid_response');
    }
    int bounded(String key, int min, int max) {
      final item = value[key];
      if (item is! int || item < min || item > max) {
        throw const LarenorServerException('invalid_response');
      }
      return item;
    }

    return EvChargerCapability(
      id: value['chargerId'] as String,
      label: label,
      chargerRevision: bounded('chargerRevision', 1, 0x7fffffffffffffff),
      scheduleRevision: bounded('scheduleRevision', 1, 0x7fffffffffffffff),
      tariffRevision: bounded('tariffRevision', 1, 0x7fffffffffffffff),
      powerBudgetRevision: bounded(
        'powerBudgetRevision',
        1,
        0x7fffffffffffffff,
      ),
      currentSoc: bounded('currentSoc', 0, 100),
      batteryCapacityWh: bounded('batteryCapacityWh', 1, 500000),
      maxCurrentAmp: bounded('maxCurrentAmp', 1, 80),
    );
  }

  @override
  Future<EvChargePlan> preview({
    required EvChargerCapability charger,
    required String previewId,
    required DateTime departure,
    required int targetSoc,
  }) => _run(() async {
    final body = serverObject(
      await _api.request(
        'POST',
        '$_root/chargers/${charger.id}/previews',
        token: _session.accessToken,
        body: {
          'schemaVersion': 1,
          'previewId': previewId,
          'expectedChargerRevision': charger.chargerRevision,
          'expectedScheduleRevision': charger.scheduleRevision,
          'expectedTariffRevision': charger.tariffRevision,
          'expectedPowerBudgetRevision': charger.powerBudgetRevision,
          'departureAtMs': departure.toUtc().millisecondsSinceEpoch,
          'targetSoc': targetSoc,
        },
      ),
    );
    if (body.length != 2 || body['schemaVersion'] != 1) {
      throw const LarenorServerException('invalid_response');
    }
    return _plan(body['preview'], charger: charger, previewId: previewId);
  });

  EvChargePlan _plan(
    Object? raw, {
    required EvChargerCapability charger,
    required String previewId,
  }) {
    final value = serverObject(raw);
    _exact(value, const {
      'schemaVersion',
      'coreId',
      'homeId',
      'chargerId',
      'accountId',
      'sessionFamilyId',
      'chargerRevision',
      'scheduleRevision',
      'tariffRevision',
      'powerBudgetRevision',
      'previewId',
      'planHash',
      'status',
      'requiredWh',
      'providerStatus',
      'overrideExpiresAtMs',
      'slots',
    });
    final sessionFamily = value['sessionFamilyId'];
    final slots = value['slots'];
    final requiredWh = value['requiredWh'];
    final providerStatus = value['providerStatus'];
    final overrideExpiry = value['overrideExpiresAtMs'];
    if (value['schemaVersion'] != 1 ||
        value['coreId'] != _context.coreId ||
        value['homeId'] != _context.homeId ||
        value['chargerId'] != charger.id ||
        value['accountId'] != _session.user.id ||
        !_identity(sessionFamily) ||
        value['chargerRevision'] != charger.chargerRevision ||
        value['scheduleRevision'] != charger.scheduleRevision ||
        value['tariffRevision'] != charger.tariffRevision ||
        value['powerBudgetRevision'] != charger.powerBudgetRevision ||
        value['previewId'] != previewId ||
        !_hash(value['planHash']) ||
        !const {'ready', 'manual_override_active'}.contains(value['status']) ||
        requiredWh is! int ||
        requiredWh < 1 ||
        requiredWh > 500000 ||
        providerStatus is! Map ||
        providerStatus.length != 3 ||
        providerStatus['tariff'] != 'verified' ||
        providerStatus['solar'] != 'verified' ||
        providerStatus['power_budget'] != 'verified' ||
        (overrideExpiry != null &&
            (overrideExpiry is! int || overrideExpiry < 1)) ||
        slots is! List ||
        slots.length > 192) {
      throw const LarenorServerException('invalid_response');
    }
    return EvChargePlan(
      coreId: _context.coreId,
      homeId: _context.homeId,
      chargerId: charger.id,
      accountId: _session.user.id,
      sessionFamilyId: sessionFamily as String,
      previewId: previewId,
      planHash: value['planHash'] as String,
      chargerRevision: charger.chargerRevision,
      scheduleRevision: charger.scheduleRevision,
      requiredWh: requiredWh,
      status: value['status'] as String,
      slots: List.unmodifiable(slots.map(_slot)),
    );
  }

  EvChargeSlot _slot(Object? raw) {
    final value = serverObject(raw);
    _exact(value, const {
      'startAtMs',
      'endAtMs',
      'currentAmp',
      'energyWh',
      'tariffMicrosPerKwh',
      'solarSurplusW',
    });
    final start = value['startAtMs'], end = value['endAtMs'];
    final current = value['currentAmp'], energy = value['energyWh'];
    final tariff = value['tariffMicrosPerKwh'];
    final solar = value['solarSurplusW'];
    if (start is! int ||
        end is! int ||
        end <= start ||
        current is! int ||
        current < 1 ||
        current > 80 ||
        energy is! int ||
        energy < 1 ||
        energy > 500000 ||
        tariff is! int ||
        tariff < 0 ||
        tariff > 10000000 ||
        solar is! int ||
        solar < 0 ||
        solar > 100000) {
      throw const LarenorServerException('invalid_response');
    }
    return EvChargeSlot(
      start: DateTime.fromMillisecondsSinceEpoch(start, isUtc: true),
      end: DateTime.fromMillisecondsSinceEpoch(end, isUtc: true),
      currentAmp: current,
      energyWh: energy,
      tariffMicrosPerKwh: tariff,
    );
  }

  @override
  Future<EvChargeReceipt> confirm(EvChargePlan plan, String commandId) =>
      _run(() async {
        final body = serverObject(
          await _api.request(
            'POST',
            '$_root/chargers/${plan.chargerId}/commands',
            token: _session.accessToken,
            body: {
              'schemaVersion': 1,
              'previewId': plan.previewId,
              'commandId': commandId,
              'expectedPlanHash': plan.planHash,
              'expectedChargerRevision': plan.chargerRevision,
              'expectedScheduleRevision': plan.scheduleRevision,
            },
          ),
        );
        if (body.length != 2 || body['schemaVersion'] != 1) {
          throw const LarenorServerException('invalid_response');
        }
        final value = serverObject(body['receipt']);
        _exact(value, const {
          'schemaVersion',
          'coreId',
          'homeId',
          'chargerId',
          'accountId',
          'sessionFamilyId',
          'chargerRevision',
          'scheduleRevision',
          'commandId',
          'previewId',
          'planHash',
          'status',
          'applyCount',
        });
        if (value['schemaVersion'] != 1 ||
            value['coreId'] != plan.coreId ||
            value['homeId'] != plan.homeId ||
            value['chargerId'] != plan.chargerId ||
            value['accountId'] != plan.accountId ||
            value['sessionFamilyId'] != plan.sessionFamilyId ||
            value['chargerRevision'] != plan.chargerRevision ||
            value['scheduleRevision'] != plan.scheduleRevision ||
            value['commandId'] != commandId ||
            value['previewId'] != plan.previewId ||
            value['planHash'] != plan.planHash ||
            !const {
              'uncertain',
              'awaiting_readback',
              'verified',
            }.contains(value['status']) ||
            value['applyCount'] != 1) {
          throw const LarenorServerException('invalid_response');
        }
        return EvChargeReceipt(
          commandId: commandId,
          previewId: plan.previewId,
          planHash: plan.planHash,
          status: value['status'] as String,
        );
      });

  @override
  void retire() => _retired = true;
}

final class AccountEvChargingGateway implements EvChargingGateway {
  AccountEvChargingGateway({
    required ServerAccountController account,
    required bool Function() isCurrent,
  }) : _account = account,
       _current = isCurrent,
       _generation = account.generation,
       _session = account.session,
       _context = account.session?.context;
  final ServerAccountController _account;
  final bool Function() _current;
  final int _generation;
  final ServerSession? _session;
  final ServerContext? _context;
  bool _retired = false;
  bool _valid() =>
      !_retired &&
      _account.isCurrent(_generation) &&
      identical(_account.session, _session) &&
      _account.session?.context == _context &&
      _current();
  Future<T> _run<T>(Future<T> Function(EvChargingApi) action) =>
      _account.withSession((api, session) async {
        if (!_valid() || !identical(session, _session)) {
          throw const LarenorServerException('cancelled');
        }
        final gateway = EvChargingApi(api, session, isCurrent: _valid);
        final value = await action(gateway);
        if (!_valid()) throw const LarenorServerException('cancelled');
        return value;
      });
  @override
  Future<EvChargeCapability> capability() => _run((api) => api.capability());
  @override
  Future<EvChargePlan> preview({
    required EvChargerCapability charger,
    required String previewId,
    required DateTime departure,
    required int targetSoc,
  }) => _run(
    (api) => api.preview(
      charger: charger,
      previewId: previewId,
      departure: departure,
      targetSoc: targetSoc,
    ),
  );
  @override
  Future<EvChargeReceipt> confirm(EvChargePlan plan, String commandId) =>
      _run((api) => api.confirm(plan, commandId));
  @override
  void retire() => _retired = true;
}

void _exact(Map<String, Object?> value, Set<String> keys) {
  if (value.keys.toSet().difference(keys).isNotEmpty ||
      keys.difference(value.keys.toSet()).isNotEmpty) {
    throw const LarenorServerException('invalid_response');
  }
}

bool _identity(Object? value) => value is String && _id.hasMatch(value);
bool _hash(Object? value) => value is String && _digest.hasMatch(value);
bool _safeText(String value) => !value.runes.any(
  (rune) =>
      rune < 32 ||
      rune == 127 ||
      (rune >= 0x202a && rune <= 0x202e) ||
      (rune >= 0x2066 && rune <= 0x2069),
);
T _enum<T extends Enum>(List<T> values, Object? raw) =>
    values.where((value) => value.name == raw).singleOrNull ??
    (throw const LarenorServerException('invalid_response'));
