import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/room_presence/data/room_presence_source_api.dart';

import '../server/server_admin_test_support.dart';

Map<String, Object?> _service() => {
  'id': '1' * 32,
  'name': 'Verified Home Assistant',
  'kind': 'home_assistant',
  'baseUrl': 'https://ha.fixture.invalid',
  'revision': 3,
  'credentialKeys': ['token'],
  'verification': {
    'state': 'authenticated',
    'checkedAt': '2026-09-05T08:00:00Z',
    'version': '2026.9',
  },
};

Map<String, Object?> _room() => {
  'ref': {
    'schemaVersion': 1,
    'coreId': 'a' * 32,
    'homeId': 'b' * 32,
    'kind': 'room',
    'id': '2' * 32,
  },
  'label': 'Living room',
  'order': 0,
  'revision': 4,
  'aclRevision': 1,
  'permissions': {'read': true, 'write': true},
};

Map<String, Object?> _configuration({
  bool consentActive = true,
  int revision = 2,
}) => {
  'schemaVersion': 1,
  'revision': revision,
  'serviceId': '1' * 32,
  'serviceRevision': 3,
  'entityId': 'sensor.owner_room',
  'entityName': 'Owner room',
  'consentActive': consentActive,
  'maxSignalAgeMs': 30000,
  'rooms': [
    {'roomId': '2' * 32, 'roomRevision': 4, 'roomLabel': 'Living room'},
  ],
  'provider': 'home_assistant_mqtt_room',
  'advisoryOnly': true,
  'grantsAccess': false,
};

void main() {
  late AdminFixture fixture;

  setUp(() async {
    fixture = AdminFixture();
    fixture.respond = (request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path.endsWith('/configuration/setup')) {
        return fixture.json({
          'schemaVersion': 1,
          'services': [_service()],
          'rooms': [_room()],
          'provider': 'home_assistant_mqtt_room',
          'advisoryOnly': true,
          'grantsAccess': false,
        });
      }
      if (request.method == 'GET' && path.endsWith('/configuration')) {
        return fixture.json({
          'schemaVersion': 1,
          'configuration': _configuration(),
        });
      }
      if (request.method == 'GET' &&
          path.contains('/configuration/entities/')) {
        return fixture.json({
          'schemaVersion': 1,
          'entities': [
            {
              'schemaVersion': 1,
              'candidateId': '3' * 64,
              'entityId': 'sensor.owner_room',
              'name': 'Owner room',
              'platform': 'mqtt_room',
            },
          ],
        });
      }
      if (request.method == 'PUT' && path.endsWith('/configuration')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['candidateId'], '3' * 64);
        expect(body['consent'], true);
        return fixture.json({
          'schemaVersion': 1,
          'configuration': _configuration(),
        });
      }
      if (request.method == 'POST' && path.endsWith('/consent/revoke')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body, {'schemaVersion': 1, 'expectedRevision': 2});
        return fixture.json({
          'schemaVersion': 1,
          'configuration': _configuration(consentActive: false, revision: 3),
        });
      }
      return fixture.defaultResponse(request);
    };
    await fixture.account.initialize();
  });

  tearDown(() => fixture.account.dispose());

  test('setup exposes only verified opaque mqtt_room candidates', () async {
    final api = AccountRoomPresenceSourceApi(
      account: fixture.account,
      isCurrent: () => true,
    );
    final setup = await api.load();
    final entities = await api.entities(setup.services.single);
    final saved = await api.save({
      'schemaVersion': 1,
      'expectedRevision': setup.configuration?.revision,
      'serviceId': setup.services.single.id,
      'expectedServiceRevision': setup.services.single.revision,
      'entityId': entities.single.entityId,
      'candidateId': entities.single.candidateId,
      'roomId': setup.rooms.single.id,
      'expectedRoomRevision': setup.rooms.single.revision,
      'maxSignalAgeMs': 30000,
      'consent': true,
    });
    expect(saved.entityName, 'Owner room');
    final revoked = await api.revoke(saved.revision);
    expect(revoked.revision, 3);
    expect(revoked.consentActive, isFalse);
    expect(entities.single.candidateId, '3' * 64);
    expect(
      fixture.calls
          .where((call) => call.url.path.contains('/room-presence/'))
          .every(
            (call) =>
                call.headers['authorization'] ==
                'Bearer synthetic_admin_access_12345',
          ),
      isTrue,
    );
    expect(fixture.calls.join(), isNot(contains('private-ble-device-id')));
  });

  test('invented provider platform fails closed', () async {
    final api = AccountRoomPresenceSourceApi(
      account: fixture.account,
      isCurrent: () => true,
    );
    final service = (await api.load()).services.single;
    fixture.respond = (request) async {
      if (request.url.path.contains('/configuration/entities/')) {
        return fixture.json({
          'schemaVersion': 1,
          'entities': [
            {
              'schemaVersion': 1,
              'candidateId': '3' * 64,
              'entityId': 'sensor.owner_room',
              'name': 'Owner room',
              'platform': 'bluetooth',
            },
          ],
        });
      }
      return fixture.defaultResponse(request);
    };
    await expectLater(api.entities(service), throwsA(isA<Object>()));
  });
}
