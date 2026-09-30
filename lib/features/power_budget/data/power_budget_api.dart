import 'dart:math';

import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/power_budget_models.dart';

abstract interface class PowerBudgetApi {
  Future<PowerBudgetSnapshot> load();
  Future<PowerBudgetReceipt> confirm(PowerBudgetSnapshot snapshot);
  void retire();
}

final class CorePowerBudgetApi implements PowerBudgetApi {
  CorePowerBudgetApi({
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
  Future<PowerBudgetSnapshot> load() => account.withSession((
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
        '/admin/power-budget',
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

  @override
  Future<PowerBudgetReceipt> confirm(PowerBudgetSnapshot snapshot) =>
      account.withSession((api, session) async {
        _check();
        if (!identical(_session, session) ||
            !identical(account.session, session) ||
            !snapshot.commandEndpointAvailable ||
            snapshot.authority.accountId != session.user.id ||
            snapshot.authority.coreId != session.context?.coreId ||
            snapshot.authority.homeId != session.context?.homeId) {
          retire();
          throw const LarenorServerException('cancelled');
        }
        final random = Random.secure();
        final requestKey = List.generate(
          24,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        final response = _object(
          await api.request(
            'POST',
            '/admin/power-budget/confirm',
            token: session.accessToken,
            body: {
              'schemaVersion': 1,
              'previewId': snapshot.planId,
              'expectedPlanHash': snapshot.planHash,
              'requestKey': 'power-budget:$requestKey',
            },
          ),
        );
        _check();
        _keys(response, const {'receipt'});
        final value = _object(response['receipt']);
        _keys(value, const {
          'schemaVersion',
          'commandId',
          'previewId',
          'planHash',
          'status',
          'applyCount',
          'communicationLossBehavior',
        });
        final behaviors = _object(value['communicationLossBehavior']);
        final expectedLoads = snapshot.actions
            .map((value) => value.loadId)
            .toSet();
        if (_int(value['schemaVersion']) != 1 ||
            _text(value['previewId'], 128) != snapshot.planId ||
            _text(value['planHash'], 64) != snapshot.planHash ||
            _positive(value['applyCount']) != 1 ||
            behaviors.length != expectedLoads.length ||
            !behaviors.keys.toSet().containsAll(expectedLoads) ||
            snapshot.actions.any(
              (action) =>
                  behaviors[action.loadId] != action.communicationLossBehavior,
            )) {
          _invalid();
        }
        return PowerBudgetReceipt(
          commandId: _text(value['commandId'], 128),
          previewId: snapshot.planId,
          planHash: snapshot.planHash,
          status: _oneOf(value['status'], const {
            'verified',
            'awaiting_readback',
            'uncertain',
          }),
          applyCount: 1,
        );
      });

  PowerBudgetSnapshot _decode(Map<String, dynamic> raw, ServerSession session) {
    _keys(raw, const {
      'schemaVersion',
      'authority',
      'measurement',
      'plan',
      'controlCapability',
      'commandEndpointAvailable',
    });
    if (_int(raw['schemaVersion']) != 1 ||
        raw['commandEndpointAvailable'] is! bool) {
      _invalid();
    }
    final authorityRaw = _object(raw['authority']);
    _keys(authorityRaw, const {
      'coreId',
      'homeId',
      'accountId',
      'sessionId',
      'coreRevision',
      'homeRevision',
      'accountRevision',
      'meterId',
      'meterRevision',
      'tariffRevision',
      'loadRegistryRevision',
      'gridLimitRevision',
      'overrideRevision',
      'planRevision',
      'canControl',
    });
    final context = session.context!;
    final authority = PowerBudgetAuthority(
      coreId: _text(authorityRaw['coreId'], 128),
      homeId: _text(authorityRaw['homeId'], 128),
      accountId: _text(authorityRaw['accountId'], 128),
      sessionId: _text(authorityRaw['sessionId'], 128),
      meterId: _text(authorityRaw['meterId'], 128),
      routeId: routeId,
      coreRevision: _positive(authorityRaw['coreRevision']),
      homeRevision: _positive(authorityRaw['homeRevision']),
      accountRevision: _positive(authorityRaw['accountRevision']),
      meterRevision: _positive(authorityRaw['meterRevision']),
      tariffRevision: _positive(authorityRaw['tariffRevision']),
      loadRegistryRevision: _positive(authorityRaw['loadRegistryRevision']),
      gridLimitRevision: _positive(authorityRaw['gridLimitRevision']),
      overrideRevision: _positive(authorityRaw['overrideRevision']),
      planRevision: _positive(authorityRaw['planRevision']),
      clientSessionRevision: sessionRevision,
      routeRevision: routeRevision,
      canControl: authorityRaw['canControl'] == true,
    );
    if (authority.coreId != context.coreId ||
        authority.homeId != context.homeId ||
        authority.accountId != session.user.id ||
        !authority.isBounded) {
      _invalid();
    }
    final measurement = _object(raw['measurement']);
    _keys(measurement, const {
      'gridImportW',
      'gridLimitW',
      'tariffMicrosPerKwh',
      'providerStatus',
    });
    final provider = _object(measurement['providerStatus']);
    _keys(provider, const {'meter', 'tariff'});
    final plan = _object(raw['plan']);
    _keys(plan, const {
      'id',
      'status',
      'planHash',
      'planRevision',
      'requiredReductionW',
      'overrideExpiresAtMs',
      'actions',
    });
    final hash = _text(plan['planHash'], 64);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        _positive(plan['planRevision']) != authority.planRevision) {
      _invalid();
    }
    final actions = <PowerBudgetAction>[];
    final rawActions = plan['actions'];
    if (rawActions is! List || rawActions.length > 192) _invalid();
    for (final item in rawActions) {
      final value = _object(item);
      _keys(value, const {
        'loadId',
        'label',
        'loadRevision',
        'reductionW',
        'targetW',
        'priority',
        'communicationLossBehavior',
      });
      actions.add(
        PowerBudgetAction(
          loadId: _text(value['loadId'], 128),
          label: _text(value['label'], 120),
          loadRevision: _positive(value['loadRevision']),
          reductionW: _nonNegative(value['reductionW']),
          targetW: _nonNegative(value['targetW']),
          priority: _nonNegative(value['priority']),
          communicationLossBehavior: _oneOf(
            value['communicationLossBehavior'],
            const {
              'stop_charging',
              'hold_last_safe_limit',
              'provider_managed',
              'not_applicable_read_only',
            },
          ),
        ),
      );
    }
    final override = plan['overrideExpiresAtMs'];
    if (override != null && override is! int) _invalid();
    return PowerBudgetSnapshot(
      authority: authority,
      gridImportW: _nonNegative(measurement['gridImportW']),
      gridLimitW: _positive(measurement['gridLimitW']),
      tariffMicrosPerKwh: _nonNegative(measurement['tariffMicrosPerKwh']),
      meterStatus: _text(provider['meter'], 32),
      tariffStatus: _text(provider['tariff'], 32),
      planId: _text(plan['id'], 128),
      planHash: hash,
      planStatus: _oneOf(plan['status'], const {
        'ready',
        'manual_override_active',
      }),
      requiredReductionW: _nonNegative(plan['requiredReductionW']),
      overrideExpiresAtMs: override as int?,
      controlCapability: _oneOf(raw['controlCapability'], const {
        'read_only',
        'manual_required',
      }),
      commandEndpointAvailable: raw['commandEndpointAvailable'] as bool,
      actions: List.unmodifiable(actions),
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
  static int _positive(Object? value) {
    final result = _int(value);
    return result > 0 ? result : _invalid();
  }

  static int _nonNegative(Object? value) {
    final result = _int(value);
    return result >= 0 ? result : _invalid();
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

  static String _oneOf(Object? value, Set<String> allowed) {
    final result = _text(value, 64);
    return allowed.contains(result) ? result : _invalid();
  }
}
