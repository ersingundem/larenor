import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ev_charging/data/ev_charging_api.dart';
import 'package:larenor/features/ev_charging/domain/ev_charging_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const _core = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _home = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _account = 'cccccccccccccccccccccccccccccccc';
const _family = 'dddddddddddddddddddddddddddddddd';
const _charger = '33333333333333333333333333333333';
const _preview = '44444444444444444444444444444444';
const _command = '55555555555555555555555555555555';
const _hash =
    '6666666666666666666666666666666666666666666666666666666666666666';
const _token = 'ev_charging_loopback_access_token_1234567';

final class _EvCore {
  _EvCore._(this.server) {
    unawaited(_serve());
  }

  final HttpServer server;
  int capabilityCalls = 0, previewCalls = 0, confirmCalls = 0, effects = 0;
  Completer<void>? previewEntered, previewBarrier;
  final appliedCommands = <String>{};

  String get baseUrl => 'http://127.0.0.1:${server.port}';
  static Future<_EvCore> start() async =>
      _EvCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> _serve() async {
    await for (final request in server) {
      unawaited(_handle(request).catchError((Object _) {}));
    }
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async =>
      jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;

  Future<void> _handle(HttpRequest request) async {
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $_token') {
      return _json(request, {
        'error': {'code': 'unauthorized'},
      }, 401);
    }
    final root = '/api/v1/ev-charging/$_core/$_home';
    if (request.method == 'GET' && request.uri.path == '$root/capability') {
      capabilityCalls++;
      return _json(request, _capability());
    }
    if (request.method == 'POST' &&
        request.uri.path == '$root/chargers/$_charger/previews') {
      previewCalls++;
      final body = await _body(request);
      if (body['previewId'] != _preview ||
          body['expectedChargerRevision'] != 4 ||
          body['expectedScheduleRevision'] != 7 ||
          body['expectedTariffRevision'] != 5 ||
          body['expectedPowerBudgetRevision'] != 8 ||
          body['targetSoc'] != 80) {
        return _json(request, {
          'error': {'code': 'conflict'},
        }, 409);
      }
      previewEntered?.complete();
      await previewBarrier?.future;
      return _json(request, {'schemaVersion': 1, 'preview': _plan()}, 201);
    }
    if (request.method == 'POST' &&
        request.uri.path == '$root/chargers/$_charger/commands') {
      confirmCalls++;
      final body = await _body(request);
      if (body['previewId'] != _preview ||
          body['commandId'] != _command ||
          body['expectedPlanHash'] != _hash ||
          body['expectedChargerRevision'] != 4 ||
          body['expectedScheduleRevision'] != 7) {
        return _json(request, {
          'error': {'code': 'conflict'},
        }, 409);
      }
      if (appliedCommands.add(_command)) effects++;
      return _json(request, {
        'schemaVersion': 1,
        'receipt': {
          'schemaVersion': 1,
          'coreId': _core,
          'homeId': _home,
          'chargerId': _charger,
          'accountId': _account,
          'sessionFamilyId': _family,
          'chargerRevision': 4,
          'scheduleRevision': 7,
          'commandId': _command,
          'previewId': _preview,
          'planHash': _hash,
          'status': 'uncertain',
          'applyCount': 1,
        },
      }, 201);
    }
    return _json(request, {
      'error': {'code': 'not_found'},
    }, 404);
  }

  Map<String, dynamic> _capability() => {
    'schemaVersion': 1,
    'coreId': _core,
    'homeId': _home,
    'state': 'ready',
    'providerKind': 'ocpp',
    'canPlan': true,
    'canControl': true,
    'reason': 'ready',
    'chargers': [
      {
        'schemaVersion': 1,
        'chargerId': _charger,
        'label': 'Garage charger',
        'chargerRevision': 4,
        'scheduleRevision': 7,
        'tariffRevision': 5,
        'powerBudgetRevision': 8,
        'currentSoc': 40,
        'batteryCapacityWh': 40000,
        'maxCurrentAmp': 16,
      },
    ],
  };

  Map<String, dynamic> _plan() => {
    'schemaVersion': 1,
    'coreId': _core,
    'homeId': _home,
    'chargerId': _charger,
    'accountId': _account,
    'sessionFamilyId': _family,
    'chargerRevision': 4,
    'scheduleRevision': 7,
    'tariffRevision': 5,
    'powerBudgetRevision': 8,
    'previewId': _preview,
    'planHash': _hash,
    'status': 'ready',
    'requiredWh': 16000,
    'providerStatus': {
      'tariff': 'verified',
      'solar': 'verified',
      'power_budget': 'verified',
    },
    'overrideExpiresAtMs': null,
    'slots': [
      {
        'startAtMs': 1790755200000,
        'endAtMs': 1790758800000,
        'currentAmp': 16,
        'energyWh': 11000,
        'tariffMicrosPerKwh': 110000,
        'solarSurplusW': 4000,
      },
      {
        'startAtMs': 1790758800000,
        'endAtMs': 1790762400000,
        'currentAmp': 8,
        'energyWh': 5000,
        'tariffMicrosPerKwh': 180000,
        'solarSurplusW': 1000,
      },
    ],
  };

  Future<void> close() => server.close(force: true);
}

void _json(HttpRequest request, Object body, [int status = 200]) {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  unawaited(request.response.close());
}

ServerSession _session(String baseUrl) => ServerSession(
  endpoint: ServerEndpoint(baseUrl),
  accessToken: _token,
  refreshToken: 'ev_charging_loopback_refresh_token_123456',
  expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  context: ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': _core,
    'homeId': _home,
  }),
  user: const ServerUser(
    id: _account,
    username: 'admin',
    role: ServerRole.admin,
    mustChangePassword: false,
  ),
  sessionFamilyId: _family,
);

Matcher _cancelled() => throwsA(
  isA<LarenorServerException>().having(
    (error) => error.code,
    'code',
    'cancelled',
  ),
);

void main() {
  setUpAll(() => HttpOverrides.global = null);

  test('production client plans with revision-bound Core inputs and preserves uncertain single effect', () async {
    final core = await _EvCore.start();
    addTearDown(core.close);
    final transport = LarenorServerApi(endpoint: ServerEndpoint(core.baseUrl));
    addTearDown(transport.close);
    final api = EvChargingApi(
      transport,
      _session(core.baseUrl),
      isCurrent: () => true,
    );

    final capability = await api.capability();
    expect(capability.state, EvCapabilityState.ready);
    expect(capability.canControl, isTrue);
    final charger = capability.chargers.single;
    final plan = await api.preview(
      charger: charger,
      previewId: _preview,
      departure: DateTime.fromMillisecondsSinceEpoch(
        1790762400000,
        isUtc: true,
      ),
      targetSoc: 80,
    );
    expect(plan.requiredWh, 16000);
    expect(plan.slots, hasLength(2));
    expect(plan.slots.first.currentAmp, 16);

    final receipt = await api.confirm(plan, _command);
    expect(receipt.status, 'uncertain');
    expect(core.confirmCalls, 1, reason: 'uncertain ACK must not auto-replay');
    expect(core.effects, 1);

    final replay = await api.confirm(plan, _command);
    expect(replay.status, receipt.status);
    expect(core.confirmCalls, 2);
    expect(core.effects, 1, reason: 'Core command identity is idempotent');
  });

  test('late plan is discarded after route authority changes', () async {
    final core = await _EvCore.start();
    addTearDown(core.close);
    final transport = LarenorServerApi(endpoint: ServerEndpoint(core.baseUrl));
    addTearDown(transport.close);
    var current = true;
    core.previewEntered = Completer<void>();
    core.previewBarrier = Completer<void>();
    final api = EvChargingApi(
      transport,
      _session(core.baseUrl),
      isCurrent: () => current,
    );
    final charger = (await api.capability()).chargers.single;
    final pending = api.preview(
      charger: charger,
      previewId: _preview,
      departure: DateTime.fromMillisecondsSinceEpoch(
        1790762400000,
        isUtc: true,
      ),
      targetSoc: 80,
    );
    await core.previewEntered!.future;
    current = false;
    core.previewBarrier!.complete();
    await expectLater(pending, _cancelled());
  });
}
