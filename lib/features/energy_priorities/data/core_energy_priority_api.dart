import 'dart:math';

import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../../server/services/data/server_services_api.dart';
import '../../server/services/domain/server_service_models.dart';
import '../domain/energy_priority_models.dart';
import 'energy_priority_controller.dart';

final class CoreEnergyPriorityApi
    implements EnergyPriorityApi, EnergyReserveSetupApi {
  CoreEnergyPriorityApi({
    required this.account,
    required this.isCurrent,
    Random? random,
  }) : _random = random ?? Random.secure();
  final ServerAccountController account;
  final bool Function() isCurrent;
  final Random _random;
  ServerSession? _session;
  EnergyPrioritySnapshot? _boundSnapshot;
  List<EnergyReserveSource> _reserveSources = const [];
  bool _retired = false;

  ServerSession? get boundSession => _session;
  void retire() {
    _retired = true;
    _session = null;
    _boundSnapshot = null;
    _reserveSources = const [];
  }

  void _check() {
    try {
      if (!_retired && isCurrent()) return;
    } catch (_) {}
    retire();
    throw const LarenorServerException('cancelled');
  }

  Future<T> _run<T>(
    Future<T> Function(LarenorServerApi api, ServerSession session) operation,
  ) async {
    _check();
    final expected = _session;
    return account.withSession((api, session) async {
      _check();
      if (session.context == null ||
          expected != null && !identical(expected, session)) {
        retire();
        throw const LarenorServerException('cancelled');
      }
      _session ??= session;
      final value = await operation(api, session);
      _check();
      if (!identical(_session, account.session)) {
        retire();
        throw const LarenorServerException('cancelled');
      }
      return value;
    });
  }

  String _root(ServerSession session) =>
      '/energy-priorities/${session.context!.coreId}/${session.context!.homeId}';
  String _requestId() =>
      List.generate(32, (_) => _random.nextInt(16).toRadixString(16)).join();

  @override
  Future<EnergyPrioritySnapshot> load() => _run((api, session) async {
    final value = _decodeSnapshot(
      await api.request('GET', _root(session), token: session.accessToken),
      session,
    );
    final old = _boundSnapshot;
    if (old != null && !old.exactFor(value)) {
      retire();
      throw const LarenorServerException('invalid_response');
    }
    _boundSnapshot = value;
    _reserveSources = const [];
    return value;
  });

  @override
  Future<EnergyCommandPreview> preview(
    EnergyPrioritySnapshot value,
    EnergyPlanSlot slot,
  ) => _run((api, session) async {
    if (!identical(_boundSnapshot, value) ||
        !value.canControl ||
        value.inverterId == null ||
        value.inverterRevision == null ||
        !value.slots.contains(slot)) {
      throw const LarenorServerException('cancelled');
    }
    final requestId = _requestId();
    final raw = await api.request(
      'POST',
      '${_root(session)}/previews',
      token: session.accessToken,
      body: {
        'schemaVersion': 1,
        'requestId': requestId,
        'planId': value.planId,
        'inputDigest': value.inputDigest,
        'slotIndex': slot.index,
        'inverterId': value.inverterId,
        'expectedInverterRevision': value.inverterRevision,
        'expectedAccountRevision': value.accountRevision,
        'expectedHomeRevision': value.homeRevision,
      },
    );
    return _decodePreview(raw, value, slot, requestId);
  });

  @override
  Future<EnergyCommandResult> confirm(EnergyCommandPreview value) => _run(
    (api, session) async => _decodeResult(
      await api.request(
        'POST',
        '${_root(session)}/previews/${value.requestId}/confirm',
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'confirmationToken': value.confirmationToken,
        },
      ),
      value,
    ),
  );

  @override
  Future<EnergyCommandResult> readback(EnergyCommandPreview value) => _run(
    (api, session) async => _decodeResult(
      await api.request(
        'GET',
        '${_root(session)}/commands/${value.requestId}',
        token: session.accessToken,
      ),
      value,
    ),
  );

  @override
  Future<EnergyReservePreview> previewReserve(EnergyPrioritySnapshot value) =>
      _run((api, session) async {
        if (!identical(_boundSnapshot, value) ||
            !value.canControl ||
            !value.canSetReserve ||
            value.inverterId == null ||
            value.inverterRevision == null) {
          throw const LarenorServerException('cancelled');
        }
        final requestId = _requestId();
        return _decodeReservePreview(
          await api.request(
            'POST',
            '${_root(session)}/reserve-previews',
            token: session.accessToken,
            body: {
              'schemaVersion': 1,
              'requestId': requestId,
              'inputDigest': value.inputDigest,
              'inverterId': value.inverterId,
              'expectedInverterRevision': value.inverterRevision,
              'expectedAccountRevision': value.accountRevision,
              'expectedHomeRevision': value.homeRevision,
              'targetReservePercent': value.reservePercent,
            },
          ),
          value,
          requestId,
        );
      });

  @override
  Future<EnergyReserveResult> confirmReserve(EnergyReservePreview value) =>
      _run(
        (api, session) async => _decodeReserveResult(
          await api.request(
            'POST',
            '${_root(session)}/reserve-previews/${value.requestId}/confirm',
            token: session.accessToken,
            body: {
              'schemaVersion': 1,
              'confirmationToken': value.confirmationToken,
            },
          ),
          value,
        ),
      );

  @override
  Future<EnergyReserveResult> readbackReserve(EnergyReservePreview value) =>
      _run(
        (api, session) async => _decodeReserveResult(
          await api.request(
            'GET',
            '${_root(session)}/reserve-commands/${value.requestId}',
            token: session.accessToken,
          ),
          value,
        ),
      );

  @override
  Future<List<EnergyReserveSource>> loadReserveSources(
    EnergyPrioritySnapshot snapshot,
  ) => _run((api, session) async {
    if (!identical(_boundSnapshot, snapshot) || !snapshot.canAdminister) {
      throw const LarenorServerException('cancelled');
    }
    final services = await ServerServicesApi(api, session.accessToken).list();
    final result = <EnergyReserveSource>[];
    for (final service in services.where(
      (value) =>
          value.kind == ServerServiceKind.homeAssistant &&
          value.verification.state ==
              ServerServiceVerificationState.authenticated,
    )) {
      var bindingRevision = 0;
      String? model;
      try {
        final value = _decodeReserveBinding(
          await api.request(
            'GET',
            '${_root(session)}/providers/fronius/${service.id}/reserve-binding',
            token: session.accessToken,
          ),
          snapshot,
          service,
        );
        bindingRevision = value.$1;
        model = value.$2;
      } on LarenorServerException catch (error) {
        if (error.code != 'not_found') rethrow;
      }
      result.add(
        EnergyReserveSource(
          serviceId: service.id,
          serviceRevision: service.revision,
          name: service.name,
          bindingRevision: bindingRevision,
          boundModel: model,
        ),
      );
    }
    _reserveSources = List.unmodifiable(result);
    return _reserveSources;
  });

  @override
  Future<void> acceptReserveSource(
    EnergyPrioritySnapshot snapshot,
    EnergyReserveSource source,
    String entityId,
  ) => _run((api, session) async {
    if (!identical(_boundSnapshot, snapshot) ||
        !snapshot.canAdminister ||
        !_reserveSources.contains(source) ||
        !RegExp(r'^number\.[a-z0-9_]{1,249}$').hasMatch(entityId)) {
      throw const LarenorServerException('invalid_request');
    }
    final value = await api.request(
      'PUT',
      '${_root(session)}/providers/fronius/${source.serviceId}/reserve-binding',
      token: session.accessToken,
      body: {
        'schemaVersion': 1,
        'expectedServiceRevision': source.serviceRevision,
        'expectedBindingRevision': source.bindingRevision,
        'batteryId': snapshot.batteryId,
        'batteryProviderRevision': snapshot.batteryProviderRevision,
        'reserveEntityId': entityId,
      },
    );
    final record = _object(value, const {'schemaVersion', 'bindingRevision'});
    if (record['schemaVersion'] != 1 ||
        _integer(record['bindingRevision']) != source.bindingRevision + 1) {
      throw _invalid;
    }
    _reserveSources = const [];
  });
}

(int, String) _decodeReserveBinding(
  Object? raw,
  EnergyPrioritySnapshot snapshot,
  ServerService service,
) {
  final value = _object(raw, const {
    'schemaVersion',
    'serviceId',
    'serviceRevision',
    'bindingRevision',
    'batteryId',
    'batteryProviderRevision',
    'controlSemantics',
    'integration',
    'model',
  });
  final model = value['model'];
  if (value['schemaVersion'] != 1 ||
      value['serviceId'] != service.id ||
      value['serviceRevision'] != service.revision ||
      value['batteryId'] != snapshot.batteryId ||
      value['batteryProviderRevision'] != snapshot.batteryProviderRevision ||
      value['controlSemantics'] != 'reserve_percent' ||
      value['integration'] != 'fronius' ||
      model is! String ||
      model.isEmpty ||
      model.length > 128) {
    throw _invalid;
  }
  return (_integer(value['bindingRevision']), model);
}

EnergyPrioritySnapshot _decodeSnapshot(Object? raw, ServerSession session) {
  final root = _object(raw, const {
    'schemaVersion',
    'authority',
    'inputs',
    'plan',
    'inverter',
  });
  if (root['schemaVersion'] != 1) throw _invalid;
  final context = session.context!;
  final authority = _object(root['authority'], const {
    'schemaVersion',
    'coreId',
    'homeId',
    'homeRevision',
    'accountId',
    'accountRevision',
    'memberRevision',
    'sessionFamilyId',
    'role',
    'active',
    'canPlan',
    'canControl',
  });
  if (authority['schemaVersion'] != 1 ||
      authority['coreId'] != context.coreId ||
      authority['homeId'] != context.homeId ||
      authority['accountId'] != session.user.id ||
      authority['role'] != session.user.role.name ||
      authority['active'] != true ||
      authority['canPlan'] != true ||
      authority['canControl'] is! bool) {
    throw _invalid;
  }
  final inputs = _object(root['inputs'], const {
    'schemaVersion',
    'coreId',
    'homeId',
    'homeRevision',
    'meter',
    'forecast',
    'tariff',
    'battery',
    'reserve',
    'manualOverride',
  });
  final forecast = _object(inputs['forecast'], const {
    'schemaVersion',
    'resourceId',
    'revision',
    'providerRevision',
    'generatedAtMs',
    'startsAtMs',
    'slotDurationSeconds',
    'solarEnergyWh',
    'loadEnergyWh',
  });
  final meter = _object(inputs['meter'], const {
    'schemaVersion',
    'resourceId',
    'revision',
    'providerRevision',
    'capturedAtMs',
    'gridImportPowerW',
    'gridExportPowerW',
  });
  final tariff = _object(inputs['tariff'], const {
    'schemaVersion',
    'resourceId',
    'revision',
    'startsAtMs',
    'slotDurationSeconds',
    'importPriceMicrosPerKwh',
    'exportPriceMicrosPerKwh',
  });
  final battery = _object(inputs['battery'], const {
    'schemaVersion',
    'resourceId',
    'revision',
    'providerRevision',
    'capturedAtMs',
    'capacityWh',
    'stateOfChargeWh',
    'minimumSocWh',
    'maximumSocWh',
    'maxChargePowerW',
    'maxDischargePowerW',
  });
  final reserve = _object(inputs['reserve'], const {
    'schemaVersion',
    'revision',
    'backupReservePercent',
  });
  final plan = _object(root['plan'], const {
    'schemaVersion',
    'planId',
    'coreId',
    'homeId',
    'homeRevision',
    'batteryId',
    'batteryRevision',
    'batteryProviderRevision',
    'meterRevision',
    'forecastRevision',
    'forecastProviderRevision',
    'tariffRevision',
    'reserveRevision',
    'overrideRevision',
    'inputDigest',
    'advisory',
    'automaticExecutionAllowed',
    'overrideStatus',
    'overrideExpiresAtMs',
    'slots',
  });
  final solar = _integers(forecast['solarEnergyWh']);
  final load = _integers(forecast['loadEnergyWh']);
  final prices = _integers(tariff['importPriceMicrosPerKwh'], signed: true);
  final rawSlots = plan['slots'];
  if (rawSlots is! List || rawSlots.isEmpty || rawSlots.length > 96) {
    throw _invalid;
  }
  final slots = rawSlots
      .map((rawSlot) {
        final slot = _object(rawSlot, const {
          'schemaVersion',
          'index',
          'startsAtMs',
          'action',
          'powerW',
          'projectedSocWh',
          'reason',
        });
        final action = switch (slot['action']) {
          'charge' => EnergyPlanAction.charge,
          'discharge' => EnergyPlanAction.discharge,
          'hold' => EnergyPlanAction.hold,
          _ => throw _invalid,
        };
        final index = _integer(slot['index'], zero: true);
        final reason = _text(slot['reason']);
        if (index >= rawSlots.length ||
            !const {
              'solar_surplus',
              'high_tariff_deficit',
              'manual_override',
              'safety_limit',
              'balanced',
            }.contains(reason)) {
          throw _invalid;
        }
        return EnergyPlanSlot(
          index: index,
          action: action,
          powerW: _integer(slot['powerW'], zero: true),
          projectedSocWh: _integer(slot['projectedSocWh'], zero: true),
          reason: reason,
          startsAt: _instant(slot['startsAtMs']),
        );
      })
      .toList(growable: false);
  final capacity = _integer(battery['capacityWh']);
  final soc = _integer(battery['stateOfChargeWh'], zero: true);
  final manual = inputs['manualOverride'] == null
      ? null
      : _object(inputs['manualOverride'], const {
          'schemaVersion',
          'revision',
          'mode',
          'powerW',
          'expiresAtMs',
        });
  final inverter = root['inverter'] == null
      ? null
      : _object(root['inverter'], const {
          'schemaVersion',
          'inverterId',
          'revision',
          'canCharge',
          'canDischarge',
          'writable',
          'physicalAcceptance',
          'canSetReserve',
          'controlSemantics',
        });
  final canControl = authority['canControl'] as bool;
  if (inputs['schemaVersion'] != 1 ||
      inputs['coreId'] != context.coreId ||
      inputs['homeId'] != context.homeId ||
      inputs['homeRevision'] != authority['homeRevision'] ||
      meter['schemaVersion'] != 1 ||
      forecast['schemaVersion'] != 1 ||
      tariff['schemaVersion'] != 1 ||
      battery['schemaVersion'] != 1 ||
      reserve['schemaVersion'] != 1 ||
      plan['schemaVersion'] != 1 ||
      plan['coreId'] != context.coreId ||
      plan['homeId'] != context.homeId ||
      plan['homeRevision'] != authority['homeRevision'] ||
      plan['advisory'] != true ||
      plan['automaticExecutionAllowed'] != false ||
      plan['batteryId'] != battery['resourceId'] ||
      plan['batteryRevision'] != battery['revision'] ||
      plan['batteryProviderRevision'] != battery['providerRevision'] ||
      plan['meterRevision'] != meter['revision'] ||
      plan['forecastRevision'] != forecast['revision'] ||
      plan['forecastProviderRevision'] != forecast['providerRevision'] ||
      plan['tariffRevision'] != tariff['revision'] ||
      plan['reserveRevision'] != reserve['revision'] ||
      plan['overrideRevision'] != manual?['revision'] ||
      solar.length != load.length ||
      solar.length != prices.length ||
      slots.length != solar.length ||
      slots.asMap().entries.any(
        (entry) =>
            entry.key != entry.value.index ||
            entry.value.projectedSocWh > capacity,
      ) ||
      soc > capacity ||
      manual != null &&
          (manual['schemaVersion'] != 1 ||
              !const {
                'charge',
                'discharge',
                'hold',
              }.contains(manual['mode'])) ||
      canControl != (inverter?['writable'] == true) ||
      inverter != null &&
          (inverter['schemaVersion'] != 1 ||
              inverter['canCharge'] is! bool ||
              inverter['canDischarge'] is! bool ||
              inverter['canSetReserve'] is! bool ||
              !const {
                'exact_power',
                'reserve_percent',
                'none',
              }.contains(inverter['controlSemantics']) ||
              inverter['physicalAcceptance'] != 'manual')) {
    throw _invalid;
  }
  return EnergyPrioritySnapshot(
    coreId: context.coreId,
    homeId: context.homeId,
    accountId: _identity(authority['accountId']),
    sessionFamilyId: _identity(authority['sessionFamilyId']),
    homeRevision: _integer(authority['homeRevision']),
    accountRevision: _integer(authority['accountRevision']),
    canAdminister: session.user.canAdminister,
    canControl: canControl,
    canCharge: inverter?['canCharge'] == true && inverter?['writable'] == true,
    canDischarge:
        inverter?['canDischarge'] == true && inverter?['writable'] == true,
    canSetReserve:
        inverter?['canSetReserve'] == true && inverter?['writable'] == true,
    planId: _identity(plan['planId']),
    inputDigest: _digest(plan['inputDigest']),
    batteryId: _identity(battery['resourceId']),
    batteryRevision: _integer(battery['revision']),
    batteryProviderRevision: _integer(battery['providerRevision']),
    inverterId: inverter == null ? null : _identity(inverter['inverterId']),
    inverterRevision: inverter == null ? null : _integer(inverter['revision']),
    reservePercent: _percent(reserve['backupReservePercent']),
    stateOfChargePercent: (soc * 100 / capacity).round().clamp(0, 100),
    solarEnergyWh: solar.fold(0, (sum, value) => sum + value),
    consumptionEnergyWh: load.fold(0, (sum, value) => sum + value),
    importPriceMicrosPerKwh: prices.reduce(max),
    slots: slots,
    meterCapturedAt: _instant(meter['capturedAtMs']),
    batteryCapturedAt: _instant(battery['capturedAtMs']),
    forecastGeneratedAt: _instant(forecast['generatedAtMs']),
    slotDuration: Duration(
      seconds: _durationSeconds(forecast['slotDurationSeconds']),
    ),
  );
}

EnergyCommandPreview _decodePreview(
  Object? raw,
  EnergyPrioritySnapshot snapshot,
  EnergyPlanSlot slot,
  String requestId,
) {
  final value = _object(raw, const {
    'schemaVersion',
    'requestId',
    'planId',
    'coreId',
    'homeId',
    'accountId',
    'accountRevision',
    'memberRevision',
    'sessionFamilyId',
    'inverterId',
    'expectedInverterRevision',
    'batteryId',
    'expectedBatteryRevision',
    'inputDigest',
    'targetPowerW',
    'expiresAtMs',
    'confirmationToken',
  });
  final target = slot.action == EnergyPlanAction.discharge
      ? -slot.powerW
      : slot.powerW;
  if (value['schemaVersion'] != 1 ||
      value['requestId'] != requestId ||
      value['planId'] != snapshot.planId ||
      value['coreId'] != snapshot.coreId ||
      value['homeId'] != snapshot.homeId ||
      value['accountId'] != snapshot.accountId ||
      value['accountRevision'] != snapshot.accountRevision ||
      value['sessionFamilyId'] != snapshot.sessionFamilyId ||
      value['inverterId'] != snapshot.inverterId ||
      value['expectedInverterRevision'] != snapshot.inverterRevision ||
      value['batteryId'] != snapshot.batteryId ||
      value['expectedBatteryRevision'] != snapshot.batteryRevision ||
      value['inputDigest'] != snapshot.inputDigest ||
      value['targetPowerW'] != target) {
    throw _invalid;
  }
  return EnergyCommandPreview(
    requestId: requestId,
    planId: snapshot.planId,
    inputDigest: snapshot.inputDigest,
    coreId: snapshot.coreId,
    homeId: snapshot.homeId,
    accountId: snapshot.accountId,
    sessionFamilyId: snapshot.sessionFamilyId,
    inverterId: snapshot.inverterId!,
    inverterRevision: snapshot.inverterRevision!,
    batteryId: snapshot.batteryId,
    batteryRevision: snapshot.batteryRevision,
    targetPowerW: target,
    confirmationToken: _digest(value['confirmationToken']),
  );
}

EnergyCommandResult _decodeResult(Object? raw, EnergyCommandPreview preview) {
  final value = _object(raw, const {
    'schemaVersion',
    'requestId',
    'status',
    'reason',
    'readbackVerified',
    'readback',
  });
  if (value['schemaVersion'] != 1 || value['requestId'] != preview.requestId) {
    throw _invalid;
  }
  if (value['status'] != 'confirmed' ||
      value['reason'] != null ||
      value['readbackVerified'] != true) {
    return EnergyCommandResult(
      requestId: preview.requestId,
      verified: false,
      targetPowerW: null,
      observedPowerW: null,
    );
  }
  final readback = _object(value['readback'], const {
    'schemaVersion',
    'requestId',
    'coreId',
    'homeId',
    'inverterId',
    'inverterRevision',
    'batteryId',
    'batteryRevision',
    'inputDigest',
    'targetPowerW',
    'observedPowerW',
    'status',
  });
  if (readback['schemaVersion'] != 1 ||
      readback['requestId'] != preview.requestId ||
      readback['coreId'] != preview.coreId ||
      readback['homeId'] != preview.homeId ||
      readback['inverterId'] != preview.inverterId ||
      readback['inverterRevision'] != preview.inverterRevision ||
      readback['batteryId'] != preview.batteryId ||
      readback['batteryRevision'] != preview.batteryRevision ||
      readback['inputDigest'] != preview.inputDigest ||
      readback['status'] != 'applied') {
    throw _invalid;
  }
  return EnergyCommandResult(
    requestId: preview.requestId,
    verified: true,
    targetPowerW: _signed(readback['targetPowerW']),
    observedPowerW: _signed(readback['observedPowerW']),
  );
}

EnergyReservePreview _decodeReservePreview(
  Object? raw,
  EnergyPrioritySnapshot snapshot,
  String requestId,
) {
  final value = _object(raw, const {
    'schemaVersion',
    'requestId',
    'coreId',
    'homeId',
    'accountId',
    'accountRevision',
    'memberRevision',
    'sessionFamilyId',
    'inverterId',
    'inverterRevision',
    'batteryId',
    'batteryRevision',
    'batteryProviderRevision',
    'inputDigest',
    'targetReservePercent',
    'expiresAtMs',
    'confirmationToken',
  });
  if (value['schemaVersion'] != 1 ||
      value['requestId'] != requestId ||
      value['coreId'] != snapshot.coreId ||
      value['homeId'] != snapshot.homeId ||
      value['accountId'] != snapshot.accountId ||
      value['accountRevision'] != snapshot.accountRevision ||
      value['sessionFamilyId'] != snapshot.sessionFamilyId ||
      value['inverterId'] != snapshot.inverterId ||
      value['inverterRevision'] != snapshot.inverterRevision ||
      value['batteryId'] != snapshot.batteryId ||
      value['batteryRevision'] != snapshot.batteryRevision ||
      value['batteryProviderRevision'] != snapshot.batteryProviderRevision ||
      value['inputDigest'] != snapshot.inputDigest ||
      value['targetReservePercent'] != snapshot.reservePercent) {
    throw _invalid;
  }
  return EnergyReservePreview(
    requestId: requestId,
    inputDigest: snapshot.inputDigest,
    coreId: snapshot.coreId,
    homeId: snapshot.homeId,
    accountId: snapshot.accountId,
    sessionFamilyId: snapshot.sessionFamilyId,
    inverterId: snapshot.inverterId!,
    inverterRevision: snapshot.inverterRevision!,
    batteryId: snapshot.batteryId,
    batteryRevision: snapshot.batteryRevision,
    batteryProviderRevision: snapshot.batteryProviderRevision,
    targetReservePercent: snapshot.reservePercent,
    confirmationToken: _digest(value['confirmationToken']),
  );
}

EnergyReserveResult _decodeReserveResult(
  Object? raw,
  EnergyReservePreview preview,
) {
  final value = _object(raw, const {
    'schemaVersion',
    'requestId',
    'status',
    'targetReservePercent',
    'observedReservePercent',
    'bindingRevision',
  });
  if (value['schemaVersion'] != 1 ||
      value['requestId'] != preview.requestId ||
      value['targetReservePercent'] != preview.targetReservePercent ||
      !const {'confirmed', 'uncertain', 'mismatch'}.contains(value['status'])) {
    throw _invalid;
  }
  final observed = value['observedReservePercent'];
  return EnergyReserveResult(
    requestId: preview.requestId,
    confirmed: value['status'] == 'confirmed',
    targetReservePercent: preview.targetReservePercent,
    observedReservePercent: observed == null ? null : _percent(observed),
    bindingRevision: _integer(value['bindingRevision']),
  );
}

const _invalid = LarenorServerException('invalid_response');
Map<String, dynamic> _object(Object? raw, Set<String> keys) {
  final value = serverObject(raw);
  if (value.keys.toSet().difference(keys).isNotEmpty ||
      keys.difference(value.keys.toSet()).isNotEmpty) {
    throw _invalid;
  }
  return value;
}

String _identity(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value)
    ? value
    : throw _invalid;
String _digest(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value)
    ? value
    : throw _invalid;
String _text(Object? value) =>
    value is String && value.isNotEmpty && value.length <= 64
    ? value
    : throw _invalid;
int _integer(Object? value, {bool zero = false}) =>
    value is int && value >= (zero ? 0 : 1) && value <= 0x7fffffffffffffff
    ? value
    : throw _invalid;
int _signed(Object? value) =>
    value is int && value >= -1000000000 && value <= 1000000000
    ? value
    : throw _invalid;
int _percent(Object? value) =>
    value is int && value >= 0 && value <= 100 ? value : throw _invalid;
DateTime _instant(Object? value) => DateTime.fromMillisecondsSinceEpoch(
  _integer(value, zero: true),
  isUtc: true,
);
int _durationSeconds(Object? value) {
  final seconds = _integer(value);
  if (seconds < 300 || seconds > 3600) throw _invalid;
  return seconds;
}

List<int> _integers(Object? raw, {bool signed = false}) {
  if (raw is! List || raw.isEmpty || raw.length > 96) throw _invalid;
  return raw
      .map((value) => signed ? _signed(value) : _integer(value, zero: true))
      .toList(growable: false);
}
