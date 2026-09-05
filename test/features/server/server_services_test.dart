import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/services/data/server_services_api.dart';
import 'package:larenor/features/server/services/data/server_services_controller.dart';
import 'package:larenor/features/server/services/domain/server_service_models.dart';

import 'server_admin_test_support.dart';

const serviceId = 'dddddddddddddddddddddddddddddddd';
Map<String, dynamic> serviceJson({int revision = 1, String state = 'never'}) =>
    {
      'id': serviceId,
      'name': 'Living room media',
      'kind': 'jellyfin',
      'baseUrl': 'https://media.example.test',
      'revision': revision,
      'credentialKeys': ['token'],
      'verification': {
        'state': state,
        'checkedAt': state == 'never' ? null : '2026-09-05T09:00:00Z',
        'version': state == 'authenticated' ? '10.11' : null,
      },
    };

class ServicesFixture extends AdminFixture {
  ServicesFixture({super.role, super.mustChange}) {
    respond = (request) async => serviceResponse(request);
  }
  final records = <Map<String, dynamic>>[];
  http.Response serviceResponse(http.Request request) {
    if (request.url.path.endsWith('/context')) return defaultResponse(request);
    if (request.method == 'GET') return this.json({'services': records});
    if (request.method == 'DELETE') {
      if (request.url.queryParameters['expectedRevision'] !=
          '${records.single['revision']}') {
        return this.json({
          'error': {'code': 'revision_conflict'},
        }, 409);
      }
      records.clear();
      return http.Response('', 204);
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (request.url.path.endsWith('/check')) {
      if (body['expectedRevision'] != records.single['revision']) {
        return this.json({
          'error': {'code': 'revision_conflict'},
        }, 409);
      }
      records.single['verification'] = serviceJson(
        state: 'authenticated',
      )['verification'];
    } else if (request.method == 'POST') {
      records.add({
        ...serviceJson(),
        'name': body['name'],
        'kind': body['kind'],
        'baseUrl': body['baseUrl'],
        'credentialKeys': (body['credentials'] as Map).keys.toList(),
      });
    } else {
      if (body['expectedRevision'] != records.single['revision']) {
        return this.json({
          'error': {'code': 'revision_conflict'},
        }, 409);
      }
      records.single.addAll({
        'name': body['name'],
        'baseUrl': body['baseUrl'],
        'revision':
            (records.single['revision'] as int) +
            (body['name'] != records.single['name'] ||
                    body['baseUrl'] != records.single['baseUrl'] ||
                    body.containsKey('credentials')
                ? 1
                : 0),
        if (body['baseUrl'] != records.single['baseUrl'] ||
            body.containsKey('credentials'))
          'verification': serviceJson()['verification'],
        if (body.containsKey('credentials'))
          'credentialKeys': (body['credentials'] as Map).keys.toList(),
      });
    }
    return this.json({
      'service': records.single,
    }, request.method == 'POST' ? 201 : 200);
  }
}

void main() {
  test('credential forms accept only the probe key combinations', () {
    for (final kind in [
      ServerServiceKind.homeAssistant,
      ServerServiceKind.musicAssistant,
    ]) {
      expect(
        validServiceCredentialCombination(kind, {'token': 'sample'}),
        isTrue,
      );
      expect(
        validServiceCredentialCombination(kind, {'apiKey': 'sample'}),
        isFalse,
      );
    }
    for (final kind in [
      ServerServiceKind.sonarr,
      ServerServiceKind.radarr,
      ServerServiceKind.lidarr,
      ServerServiceKind.readarr,
      ServerServiceKind.prowlarr,
      ServerServiceKind.bazarr,
      ServerServiceKind.seerr,
    ]) {
      expect(
        validServiceCredentialCombination(kind, {'apiKey': 'sample'}),
        isTrue,
      );
      expect(
        validServiceCredentialCombination(kind, {'token': 'sample'}),
        isFalse,
      );
    }
    for (final kind in [ServerServiceKind.jellyfin, ServerServiceKind.immich]) {
      expect(
        validServiceCredentialCombination(kind, {'apiKey': 'sample'}),
        isTrue,
      );
      expect(
        validServiceCredentialCombination(kind, {'token': 'sample'}),
        isTrue,
      );
      expect(
        validServiceCredentialCombination(kind, {
          'token': 'sample',
          'apiKey': 'other',
        }),
        isFalse,
      );
    }
    for (final kind in [
      ServerServiceKind.qbittorrent,
      ServerServiceKind.adguard,
      ServerServiceKind.keenetic,
      ServerServiceKind.proxmox,
    ]) {
      expect(
        validServiceCredentialCombination(kind, {
          'username': 'admin',
          'password': 'sample',
        }),
        isTrue,
      );
      expect(
        validServiceCredentialCombination(kind, {'username': 'admin'}),
        isFalse,
      );
    }
    expect(
      validServiceCredentialCombination(ServerServiceKind.proxmox, {
        'token': 'admin@pve!reader=sample',
      }),
      isTrue,
    );
    expect(
      validServiceCredentialCombination(ServerServiceKind.frigate, {
        'token': 'sample',
      }),
      isFalse,
    );
    for (final kind in ServerServiceKind.values) {
      expect(validServiceCredentialCombination(kind, {}), isTrue);
      expect(
        validServiceCredentialCombination(kind, {'userId': 'sample'}),
        isFalse,
      );
    }
  });

  test(
    'service metadata is strict, bounded and never accepts returned secrets',
    () {
      final service = ServerService.fromJson(serviceJson());
      expect(service.kind, ServerServiceKind.jellyfin);
      expect(service.verification.state, ServerServiceVerificationState.never);
      expect(service.toString(), isNot(contains('media.example')));
      for (final change in <Map<String, dynamic>>[
        {
          'credentials': {'token': 'synthetic-secret'},
        },
        {'id': '../secret'},
        {'name': 'a' * 81},
        {'kind': 'arbitrary'},
        {'baseUrl': 'https://user:secret@host.test'},
        {'revision': 0},
        {
          'credentialKeys': ['token', 'token'],
        },
        {
          'credentialKeys': ['unknown'],
        },
        {
          'verification': {
            'state': 'connected',
            'checkedAt': null,
            'version': null,
          },
        },
      ]) {
        expect(
          () => ServerService.fromJson({...serviceJson(), ...change}),
          throwsA(isA<LarenorServerException>()),
        );
      }
    },
  );

  test(
    'CRUD/check sends revisions, never reuses endpoint credentials implicitly',
    () async {
      final fixture = ServicesFixture();
      await fixture.account.initialize();
      await fixture.account.withSession((api, session) async {
        final client = ServerServicesApi(api, session.accessToken);
        expect(await client.list(), isEmpty);
        final created = await client.create(
          name: 'Media',
          kind: ServerServiceKind.jellyfin,
          baseUrl: 'https://media.example.test',
          credentials: {'token': 'synthetic-secret'},
        );
        expect(created.credentialKeys, ['token']);
        expect(jsonDecode(fixture.mutations.last.body)['credentials'], {
          'token': 'synthetic-secret',
        });
        final updated = await client.update(
          created,
          name: 'Renamed',
          baseUrl: created.baseUrl,
        );
        expect(
          jsonDecode(fixture.mutations.last.body).containsKey('credentials'),
          isFalse,
        );
        await expectLater(
          client.update(updated, name: 'Other', baseUrl: 'https://other.test'),
          throwsA(isA<LarenorServerException>()),
        );
        final cleared = await client.update(
          updated,
          name: 'Other',
          baseUrl: 'https://other.test',
          credentials: {},
        );
        expect(cleared.credentialKeys, isEmpty);
        final checked = await client.check(cleared);
        expect(
          checked.verification.state,
          ServerServiceVerificationState.authenticated,
        );
        expect(checked.revision, cleared.revision);
        final unchanged = await client.update(
          checked,
          name: checked.name,
          baseUrl: checked.baseUrl,
        );
        expect(unchanged.revision, checked.revision);
        expect(unchanged.verification.state, checked.verification.state);
        final renamed = await client.update(
          unchanged,
          name: 'Name only',
          baseUrl: unchanged.baseUrl,
        );
        expect(renamed.revision, unchanged.revision + 1);
        expect(renamed.verification.state, checked.verification.state);
        await client.forget(renamed);
        expect(fixture.mutations.last.method, 'DELETE');
        expect(
          fixture.mutations.last.url.queryParameters['expectedRevision'],
          '${renamed.revision}',
        );
        expect(fixture.records, isEmpty);
      });
      fixture.account.dispose();
    },
  );

  test('uncertain write requires fresh list; stale and duplicate callbacks do nothing', () async {
    final fixture = ServicesFixture()..records.add(serviceJson());
    await fixture.account.initialize();
    final controller = ServerServicesController(fixture.account);
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    var current = true;
    await controller.load(current: () => current);
    final item = controller.services.single;
    final pending = Completer<http.Response>();
    fixture.respond = (_) => pending.future;
    final write = controller.check(item, current: () => current);
    await Future<void>.delayed(Duration.zero);
    await controller.check(item, current: () => current);
    expect(fixture.mutations.length, 1);
    pending.complete(
      fixture.json({
        'error': {'code': 'revision_conflict'},
      }, 409),
    );
    await write;
    expect(controller.needsRefresh, isTrue);
    expect(controller.failure, 'revision_conflict');
    await controller.forget(item, current: () => current);
    expect(fixture.mutations.length, 1);
    fixture.respond = (request) async => fixture.serviceResponse(request);
    await controller.load(current: () => current);
    expect(controller.needsRefresh, isFalse);
    current = false;
    await controller.forget(item, current: () => current);
    expect(fixture.mutations.length, 1);
  });

  test(
    'members and forced-password accounts never issue services requests',
    () async {
      for (final fixture in [
        ServicesFixture(role: ServerRole.member),
        ServicesFixture(mustChange: true),
      ]) {
        await fixture.account.initialize();
        final controller = ServerServicesController(fixture.account);
        await controller.load(current: () => true);
        expect(fixture.adminCalls, isEmpty);
        controller.dispose();
        fixture.account.dispose();
      }
    },
  );

  test('logout discards delayed service results', () async {
    final fixture = ServicesFixture()..records.add(serviceJson());
    await fixture.account.initialize();
    final controller = ServerServicesController(fixture.account);
    final pending = Completer<http.Response>();
    fixture.respond = (_) => pending.future;
    final load = controller.load(current: () => true);
    await Future<void>.delayed(Duration.zero);
    await fixture.account.signOut();
    pending.complete(fixture.json({'services': fixture.records}));
    await load;
    expect(controller.services, isEmpty);
    controller.dispose();
    fixture.account.dispose();
  });

  test('verification schema rejects impossible states and unsafe versions', () {
    for (final verification in [
      {'state': 'never', 'checkedAt': null, 'version': '1.0'},
      {'state': 'reachable', 'checkedAt': null, 'version': null},
      {
        'state': 'authenticated',
        'checkedAt': '2026-09-05T09:00:00Z',
        'version': '<secret>',
      },
    ]) {
      expect(
        () => ServerService.fromJson({
          ...serviceJson(),
          'verification': verification,
        }),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });

  test(
    'write responses must belong to the selected connection and revision',
    () async {
      final fixture = ServicesFixture();
      await fixture.account.initialize();
      final original = ServerService.fromJson(serviceJson(revision: 4));
      await fixture.account.withSession((api, session) async {
        final client = ServerServicesApi(api, session.accessToken);
        for (final change in [
          {'id': 'ffffffffffffffffffffffffffffffff'},
          {'kind': 'sonarr'},
          {'revision': 3},
          {'revision': 5},
        ]) {
          fixture.respond = (_) async => fixture.json({
            'service': {...serviceJson(revision: 5), ...change},
          });
          await expectLater(
            client.check(original),
            throwsA(isA<LarenorServerException>()),
          );
        }
        fixture.respond = (_) async =>
            fixture.json({'service': serviceJson(revision: 6)});
        await expectLater(
          client.update(
            original,
            name: original.name,
            baseUrl: original.baseUrl,
          ),
          throwsA(isA<LarenorServerException>()),
        );
      });
      fixture.account.dispose();
    },
  );
}
