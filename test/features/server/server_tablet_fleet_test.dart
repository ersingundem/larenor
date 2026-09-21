import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/tablet_fleet/data/server_tablet_fleet_api.dart';
import 'package:larenor/features/server/tablet_fleet/data/server_tablet_fleet_controller.dart';
import 'package:larenor/features/server/tablet_fleet/domain/server_tablet_fleet_models.dart';

import 'server_admin_test_support.dart';

const coreId = 'a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0';
const homeId = 'b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0';
const standardTabletId = 'c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0';
const ownerTabletId = 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0';
const commandId = 'e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0';

Map<String, dynamic> fleetTablet({
  String id = standardTabletId,
  String name = 'Kitchen tablet',
  String mode = 'standard',
  int revision = 1,
  int desired = 1,
  int applied = 1,
  String state = 'active',
}) => {
  'schemaVersion': 1,
  'ref': {
    'schemaVersion': 1,
    'coreId': coreId,
    'homeId': homeId,
    'kind': 'managed_tablet',
    'id': id,
  },
  'revision': revision,
  'name': name,
  'platform': 'android',
  'managementMode': mode,
  'capabilities': mode == 'deviceOwner'
      ? ['notifications', 'kiosk', 'media', 'screen', 'appRestart', 'kioskLock']
      : ['notifications', 'kiosk', 'media', 'screen'],
  'clientVersion': '1.2.3',
  'desiredProfileRevision': desired,
  'appliedProfileRevision': applied,
  'state': state,
  'profileState': desired == applied ? 'current' : 'updateRequired',
  'lastSeenAt': 1789977600.0,
};

Map<String, dynamic> fleetCommand({
  String id = commandId,
  int sequence = 1,
  String kind = 'refreshDashboard',
  String state = 'pending',
  String? result,
  int policyRevision = 1,
  double expiresAt = 1789977660.0,
  double createdAt = 1789977600.0,
}) => {
  'schemaVersion': 1,
  'id': id,
  'sequence': sequence,
  'command': kind,
  'requiredMode':
      {'restartClient': 'deviceOwner', 'lockKiosk': 'deviceOwner'}[kind] ??
      'standard',
  'policyRevision': policyRevision,
  'expiresAt': expiresAt,
  'state': state,
  'result': result,
  'createdAt': createdAt,
  'completedAt': switch (state) {
    'completed' => 1789977601.0,
    'expired' => expiresAt,
    _ => null,
  },
};

class TabletFleetFixture extends AdminFixture {
  TabletFleetFixture() {
    respond = response;
  }

  final records = <Map<String, dynamic>>[
    fleetTablet(),
    fleetTablet(id: ownerTabletId, name: 'Hall tablet', mode: 'deviceOwner'),
  ];
  Map<String, dynamic> command = fleetCommand();
  Completer<http.Response>? delayedList;

  Map<String, dynamic> get listBody => {
    'schemaVersion': 1,
    'scope': {'schemaVersion': 1, 'coreId': coreId, 'homeId': homeId},
    'tablets': records,
  };

  Future<http.Response> response(http.Request request) async {
    if (request.url.path.endsWith('/context')) {
      return this.json({
        'schemaVersion': 1,
        'coreId': coreId,
        'homeId': homeId,
      });
    }
    final path = request.url.path;
    if (!path.contains('/tablet-fleet/')) return defaultResponse(request);
    if (request.method == 'GET') {
      return delayedList?.future ?? this.json(listBody);
    }
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    if (path.endsWith('/profiles/dry-run')) {
      final targets = body['targets'] as List;
      return this.json({
        'schemaVersion': 1,
        'scope': {'schemaVersion': 1, 'coreId': coreId, 'homeId': homeId},
        'requestDigest': body['requestDigest'],
        'profileRevision': body['profileRevision'],
        'rolloutPercent': body['rolloutPercent'],
        'profileSeal': '9' * 64,
        'release': {
          'applicationId': 'com.ersingundem.larenor',
          'certificateSha256': 'a' * 64,
          'versionCode': 42,
          'versionName': '1.2.3',
          'apkSha256': 'b' * 64,
        },
        'devices': [
          for (final target in targets)
            {
              'deviceId': target['deviceId'],
              'deviceRevision': target['expectedDeviceRevision'],
              'appliedProfileRevision': records.firstWhere(
                (item) => (item['ref'] as Map)['id'] == target['deviceId'],
              )['appliedProfileRevision'],
              'desiredProfileRevision': records.firstWhere(
                (item) => (item['ref'] as Map)['id'] == target['deviceId'],
              )['desiredProfileRevision'],
              'state':
                  int.parse(
                            sha256
                                .convert(
                                  utf8.encode(
                                    "${'9' * 64}:${target['deviceId']}",
                                  ),
                                )
                                .toString()
                                .substring(0, 8),
                            radix: 16,
                          ) %
                          100 <
                      (body['rolloutPercent'] as int)
                  ? 'ready'
                  : 'deferred',
              'differences': ['profileRevision'],
            },
        ],
      });
    }
    if (request.method == 'DELETE') {
      final item = records.firstWhere(
        (value) => path.endsWith(value['ref']['id']),
      );
      item['state'] = 'revoked';
      item['revision'] = (item['revision'] as int) + 1;
      return http.Response('', 204);
    }
    if (path.endsWith('/profile')) {
      final item = records.firstWhere(
        (value) => path.contains(value['ref']['id'] as String),
      );
      item['revision'] = (item['revision'] as int) + 1;
      item['desiredProfileRevision'] = body['desiredProfileRevision'];
      item['profileState'] = 'updateRequired';
      return this.json({'tablet': item});
    }
    if (path.endsWith('/heartbeat')) {
      final item = records.firstWhere(
        (value) => path.contains(value['ref']['id'] as String),
      );
      item['clientVersion'] = body['clientVersion'];
      item['appliedProfileRevision'] = body['appliedProfileRevision'];
      item['profileState'] =
          item['desiredProfileRevision'] == body['appliedProfileRevision']
          ? 'current'
          : 'updateRequired';
      return this.json({'tablet': item});
    }
    if (path.endsWith('/commands/poll')) {
      if (command['state'] == 'pending') command['state'] = 'delivered';
      return this.json({
        'schemaVersion': 1,
        'tabletRevision': body['expectedDeviceRevision'],
        'commands': [command],
        'nextAfter': null,
      });
    }
    if (path.endsWith('/complete')) {
      command = fleetCommand(
        kind: command['command'] as String,
        state: 'completed',
        result: body['result'] as String,
      );
      return this.json({'command': command});
    }
    if (path.endsWith('/commands')) {
      command = fleetCommand(
        kind: body['command'] as String,
        policyRevision: body['expectedPolicyRevision'] as int,
        expiresAt: body['expiresAt'] as double,
        createdAt: (body['expiresAt'] as double) - 60,
      );
      return this.json({'command': command}, 201);
    }
    if (path.endsWith('/devices')) {
      final record = fleetTablet(
        id: body['registrationId'] as String,
        name: body['name'] as String,
      );
      records.add(record);
      return this.json({'tablet': record}, 201);
    }
    return this.json({
      'error': {'code': 'not_found'},
    }, 404);
  }
}

void main() {
  test('records are closed, scope-bound and capability proof is exact', () {
    final standard = ManagedTablet.fromJson(fleetTablet());
    final owner = ManagedTablet.fromJson(
      fleetTablet(id: ownerTabletId, mode: 'deviceOwner'),
    );
    expect(standard.supports(TabletCommandKind.restartClient), isFalse);
    expect(owner.supports(TabletCommandKind.restartClient), isTrue);
    expect(standard.toString(), isNot(contains('Kitchen tablet')));
    for (final change in <Map<String, dynamic>>[
      {'secret': 'must-not-be-accepted'},
      {
        'ref': {...fleetTablet()['ref'], 'homeId': 'f' * 32},
      },
      {
        'capabilities': [
          ...fleetTablet()['capabilities'] as List,
          'appRestart',
        ],
      },
      {'profileState': 'current', 'desiredProfileRevision': 2},
    ]) {
      expect(
        () => ManagedTablet.fromJson({...fleetTablet(), ...change}),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });

  test(
    'rollout preview is exact, revision-bound and rejects malformed state',
    () async {
      final fixture = TabletFleetFixture();
      await fixture.account.initialize();
      await fixture.account.withSession((raw, session) async {
        final api = ServerTabletFleetApi(
          raw,
          session.accessToken,
          session.context!,
        );
        final tablets = await api.list();
        final preview = await api.previewRollout(
          tablets: tablets,
          profileRevision: 2,
          rolloutPercent: 10,
        );
        expect(preview.context, session.context);
        expect(preview.profileRevision, 2);
        expect(preview.rolloutPercent, 10);
        expect(preview.release.applicationId, 'com.ersingundem.larenor');
        expect(preview.release.certificateSha256, hasLength(64));
        expect(preview.devices, hasLength(2));
        final request = fixture.calls.last;
        expect(request.url.path, endsWith('/profiles/dry-run'));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['requestDigest'], matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(body['targets'], [
          {'deviceId': standardTabletId, 'expectedDeviceRevision': 1},
          {'deviceId': ownerTabletId, 'expectedDeviceRevision': 1},
        ]);
      });
      expect(
        () => KioskRolloutDevice.fromJson({
          'deviceId': standardTabletId,
          'deviceRevision': 1,
          'appliedProfileRevision': 1,
          'desiredProfileRevision': 1,
          'state': 'ready',
          'differences': ['applicationVersion', 'profileRevision'],
        }),
        throwsA(isA<LarenorServerException>()),
      );
      fixture.account.dispose();
    },
  );

  test('stale and malformed rollout readbacks never remain visible', () async {
    final fixture = TabletFleetFixture();
    await fixture.account.initialize();
    final controller = ServerTabletFleetController(fixture.account);
    await controller.load(current: () => true);
    await controller.previewRollout(rolloutPercent: 100, current: () => true);
    expect(controller.rolloutPreview, isNotNull);

    await controller.load(current: () => true);
    expect(controller.rolloutPreview, isNull);

    fixture.respond = (request) async {
      final response = await fixture.response(request);
      if (!request.url.path.endsWith('/profiles/dry-run')) return response;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final release = body['release'] as Map<String, dynamic>;
      return fixture.json({
        ...body,
        'release': {...release, 'applicationId': 'foreign.example'},
      });
    };
    await controller.previewRollout(rolloutPercent: 100, current: () => true);
    expect(controller.failure, 'invalid_response');
    expect(controller.rolloutPreview, isNull);

    fixture.respond = fixture.response;
    await controller.load(current: () => true);
    final pending = Completer<http.Response>();
    fixture.respond = (request) =>
        request.url.path.endsWith('/profiles/dry-run')
        ? pending.future
        : fixture.response(request);
    final stale = controller.previewRollout(
      rolloutPercent: 100,
      current: () => true,
    );
    await Future<void>.delayed(Duration.zero);
    controller.invalidate();
    pending.complete(await fixture.response(fixture.calls.last));
    await stale;
    expect(controller.rolloutPreview, isNull);
    controller.dispose();
    fixture.account.dispose();
  });

  test(
    'register heartbeat profile revoke and issue require exact readback',
    () async {
      final fixture = TabletFleetFixture();
      await fixture.account.initialize();
      await fixture.account.withSession((raw, session) async {
        final api = ServerTabletFleetApi(
          raw,
          session.accessToken,
          session.context!,
        );
        final initial = await api.list();
        expect(initial, hasLength(2));
        final registered = await api.registerStandard(
          registrationId: 'f' * 32,
          name: 'New tablet',
          clientVersion: '1.2.3',
          appliedProfileRevision: 1,
        );
        expect(registered.mode, TabletManagementMode.standard);
        final heartbeat = await api.heartbeat(
          registered,
          clientVersion: '1.2.4',
          appliedProfileRevision: 1,
        );
        expect(heartbeat.clientVersion, '1.2.4');
        final profiled = await api.updateProfile(initial.first, 2);
        expect(profiled.revision, 2);
        expect(profiled.profileState, TabletProfileState.updateRequired);
        await expectLater(
          api.issueVerified(
            profiled,
            TabletCommandKind.restartClient,
            requestKey: 'client:00000000000000000000000000000000',
            expiresAt: 1789977660.0,
          ),
          throwsA(isA<LarenorServerException>()),
        );
        final issued = await api.issueVerified(
          profiled,
          TabletCommandKind.refreshDashboard,
          requestKey: 'client:11111111111111111111111111111111',
          expiresAt: 1789977660.0,
        );
        expect(issued.kind, TabletCommandKind.refreshDashboard);
        expect(
          fixture.calls.where((call) => call.url.path.endsWith('/commands')),
          hasLength(2),
        );
        final commandBodies = fixture.calls
            .where((call) => call.url.path.endsWith('/commands'))
            .map((call) => jsonDecode(call.body) as Map<String, dynamic>);
        expect(
          commandBodies.every(
            (body) =>
                body['expectedPolicyRevision'] == 2 &&
                body['expiresAt'] == 1789977660.0,
          ),
          isTrue,
        );
        final revoked = await api.revoke(profiled);
        expect(revoked.state, TabletFleetState.revoked);
      });
      fixture.account.dispose();
    },
  );

  test('revoke rejects a stale readback revision', () async {
    final fixture = TabletFleetFixture();
    await fixture.account.initialize();
    await fixture.account.withSession((raw, session) async {
      final api = ServerTabletFleetApi(
        raw,
        session.accessToken,
        session.context!,
      );
      final tablet = (await api.list()).first;
      fixture.respond = (request) async {
        if (request.method == 'DELETE') {
          fixture.records.first['state'] = 'revoked';
          return http.Response('', 204);
        }
        return fixture.response(request);
      };
      await expectLater(
        api.revoke(tablet),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    });
    fixture.account.dispose();
  });

  test(
    'poll and completion merge replays and verify exact completion receipt',
    () async {
      final fixture = TabletFleetFixture();
      await fixture.account.initialize();
      final device = TabletFleetDeviceSessionController(fixture.account);
      final tablet = ManagedTablet.fromJson(fixture.records.first);
      device.attach(tablet);
      await device.poll(current: () => true);
      expect(device.commands, hasLength(1));
      final delivered = device.commands.values.single;
      expect(delivered.state, TabletCommandState.delivered);
      await device.complete(
        delivered,
        TabletCommandResult.unsupported,
        current: () => true,
      );
      expect(device.commands.values.single.state, TabletCommandState.completed);
      expect(
        device.commands.values.single.result,
        TabletCommandResult.unsupported,
      );
      expect(
        fixture.calls.where((call) => call.url.path.endsWith('/complete')),
        hasLength(2),
      );
      device.dispose();
      fixture.account.dispose();
    },
  );

  test('malformed and out-of-order command pages fail closed', () {
    final base = {
      'schemaVersion': 1,
      'tabletRevision': 1,
      'commands': [
        fleetCommand(id: '1' * 32, sequence: 2),
        fleetCommand(id: '2' * 32, sequence: 1),
      ],
      'nextAfter': null,
    };
    expect(
      () => ManagedTabletCommandPage.fromJson(base),
      throwsA(isA<LarenorServerException>()),
    );
    expect(
      () => ManagedTabletCommand.fromJson({
        ...fleetCommand(),
        'result': 'succeeded',
      }),
      throwsA(isA<LarenorServerException>()),
    );
    final expired = ManagedTabletCommand.fromJson(
      fleetCommand(state: 'expired', result: 'expired'),
    );
    expect(expired.state, TabletCommandState.expired);
    expect(expired.result, TabletCommandResult.expired);
    expect(expired.policyRevision, 1);
    expect(expired.expiresAt, 1789977660.0);
    expect(
      () => ManagedTabletCommandPage.fromJson({
        ...base,
        'commands': [fleetCommand(sequence: 1), fleetCommand(sequence: 2)],
      }),
      throwsA(isA<LarenorServerException>()),
    );
    for (final malformed in [
      fleetCommand(expiresAt: 1789977599.0),
      {
        ...fleetCommand(state: 'completed', result: 'succeeded'),
        'completedAt': 1789977599.0,
      },
      {
        ...fleetCommand(state: 'completed', result: 'succeeded'),
        'completedAt': 1789977661.0,
      },
    ]) {
      expect(
        () => ManagedTabletCommand.fromJson(malformed),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });

  test('malformed command readback blocks mutations until refresh', () async {
    final fixture = TabletFleetFixture();
    await fixture.account.initialize();
    final controller = ServerTabletFleetController(
      fixture.account,
      requestKey: () => 'client:22222222222222222222222222222222',
    );
    await controller.load(current: () => true);
    var issueCalls = 0;
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/commands')) {
        issueCalls++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final command = fleetCommand(kind: body['command'] as String);
        if (issueCalls == 2) command['id'] = '9' * 32;
        return fixture.json({'command': command}, 201);
      }
      return fixture.response(request);
    };
    await controller.issue(
      controller.tablets.first,
      TabletCommandKind.refreshDashboard,
      current: () => true,
    );
    expect(controller.failure, 'invalid_response');
    expect(controller.needsRefresh, isTrue);
    expect(controller.latestCommands, isEmpty);
    expect(controller.tablets, isEmpty);
    fixture.respond = fixture.response;
    await controller.load(current: () => true);
    expect(controller.failure, isNull);
    expect(controller.needsRefresh, isFalse);
    expect(controller.latestCommands.values.single.id, commandId);
    final keys = fixture.calls
        .where((call) => call.url.path.endsWith('/commands'))
        .map(
          (call) =>
              (jsonDecode(call.body) as Map<String, dynamic>)['requestKey'],
        )
        .toSet();
    expect(keys, {'client:22222222222222222222222222222222'});
    final envelopes = fixture.calls
        .where((call) => call.url.path.endsWith('/commands'))
        .map((call) => jsonDecode(call.body) as Map<String, dynamic>)
        .toList();
    expect(envelopes.map((body) => body['expiresAt']).toSet(), hasLength(1));
    expect(
      envelopes.every((body) => body['expectedPolicyRevision'] == 1),
      isTrue,
    );
    controller.dispose();
    fixture.account.dispose();
  });

  test('late list and malformed authority are discarded fail-closed', () async {
    final fixture = TabletFleetFixture();
    await fixture.account.initialize();
    final controller = ServerTabletFleetController(fixture.account);
    fixture.delayedList = Completer<http.Response>();
    final pending = controller.load(current: () => true);
    await Future<void>.delayed(Duration.zero);
    controller.invalidate();
    fixture.delayedList!.complete(fixture.json(fixture.listBody));
    await pending;
    expect(controller.tablets, isEmpty);

    fixture.delayedList = null;
    fixture.records.first['ref'] = {
      ...fixture.records.first['ref'] as Map<String, dynamic>,
      'homeId': 'f' * 32,
    };
    await controller.load(current: () => true);
    expect(controller.failure, 'invalid_response');
    expect(controller.tablets, isEmpty);
    controller.dispose();
    fixture.account.dispose();
  });

  test(
    'Core policy and expiry conflicts remain actionable fail-closed codes',
    () async {
      for (final code in ['tablet_policy_changed', 'tablet_command_expired']) {
        final fixture = TabletFleetFixture();
        await fixture.account.initialize();
        final controller = ServerTabletFleetController(fixture.account);
        await controller.load(current: () => true);
        fixture.respond = (request) async {
          if (request.url.path.endsWith('/commands')) {
            return fixture.json({
              'error': {'code': code},
            }, 409);
          }
          if (request.method == 'GET' &&
              request.url.path.contains('/tablet-fleet/')) {
            return fixture.json(fixture.listBody);
          }
          return fixture.defaultResponse(request);
        };
        await controller.issue(
          controller.tablets.first,
          TabletCommandKind.refreshDashboard,
          current: () => true,
        );
        expect(controller.failure, code);
        expect(controller.needsRefresh, isTrue);
        await controller.load(current: () => true);
        expect(
          fixture.calls.where((call) => call.url.path.endsWith('/commands')),
          hasLength(1),
        );
        controller.dispose();
        fixture.account.dispose();
      }
    },
  );
}
