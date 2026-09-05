import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:larenor/features/admin/data/admin_client.dart';
import 'package:larenor/features/admin/data/models/ha_area.dart';
import 'package:larenor/features/admin/data/models/ha_device.dart';
import 'package:larenor/features/admin/data/models/ha_registry_entry.dart';
import 'package:larenor/features/dashboard/data/room_area_sync_reader.dart';
import 'package:larenor/features/ha_client/data/ha_api_exception.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';

import '../ha_client/fake_socket.dart';

class _Admin implements HaAdminClient {
  Future<List<HaArea>> Function()? readAreas;
  @override
  Future<List<HaArea>> listAreas() async => readAreas == null
      ? const [HaArea(areaId: 'salon', name: 'Salon')]
      : readAreas!();
  @override
  Future<List<HaDevice>> listDevices() async => const [];
  @override
  Future<List<HaRegistryEntry>> listEntityRegistry() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected HA operation');
}

void main() {
  test('production reader sends only the three registry list commands and reads current states', () async {
    final socket = FakeSocket();
    final ws = HaWebSocketClient(
      baseUrl: 'http://ha.test',
      token: 'fixture',
      channelFactory: (_) => socket,
    )..connect();
    final rest = HaRestClient(
      baseUrl: 'http://ha.test',
      token: 'fixture',
      httpClient: MockClient((request) async {
        fail('Registry preview must not write or call REST: ${request.method}');
      }),
    );
    addTearDown(() {
      ws.dispose();
      rest.dispose();
    });
    await socket.authenticate();
    final reader = HaRoomAreaSyncReader(
      client: HaAdminClient(rest, ws),
      serverUrl: 'http://ha.test/',
      entities: () async => const {
        'light.lamp': HaEntity(entityId: 'light.lamp', state: 'off'),
      },
      isCurrent: () => true,
    );
    final future = reader.read();
    await flushEvents();
    final requests = socket.sent
        .where((command) => (command['type'] as String).startsWith('config/'))
        .toList();
    expect(requests.map((command) => command['type']).toSet(), {
      'config/area_registry/list',
      'config/device_registry/list',
      'config/entity_registry/list',
    });
    for (final command in requests) {
      socket.emit({
        'type': 'result',
        'id': command['id'],
        'success': true,
        'result': switch (command['type']) {
          'config/area_registry/list' => [
            {'area_id': 'salon', 'name': 'Salon'},
          ],
          'config/entity_registry/list' => [
            {'entity_id': 'light.lamp', 'area_id': 'salon'},
          ],
          _ => [],
        },
      });
    }
    final result = await future;
    expect(result.serverUrl, 'http://ha.test');
    expect(result.registry.keys, ['light.lamp']);
    expect(result.entities.keys, ['light.lamp']);
  });

  for (final status in [401, 403]) {
    test(
      'permission $status is an error, not an empty registry or leaked message',
      () async {
        final admin = _Admin()
          ..readAreas = () async => throw HaApiException(
            'fixture-sensitive-response',
            statusCode: status,
          );
        final reader = HaRoomAreaSyncReader(
          client: admin,
          serverUrl: 'http://ha.test',
          entities: () async => {},
          isCurrent: () => true,
        );
        await expectLater(
          reader.read(),
          throwsA(
            isA<RoomAreaSyncException>()
                .having((error) => error.code, 'code', 'permission')
                .having(
                  (error) => error.toString(),
                  'redaction',
                  isNot(contains('fixture-sensitive-response')),
                ),
          ),
        );
      },
    );
  }

  test('timeout is unavailable rather than an empty complete list', () async {
    final admin = _Admin()
      ..readAreas = () async =>
          throw TimeoutException('fixture-sensitive-response');
    final reader = HaRoomAreaSyncReader(
      client: admin,
      serverUrl: 'http://ha.test',
      entities: () async => {},
      isCurrent: () => true,
    );
    await expectLater(
      reader.read(),
      throwsA(
        isA<RoomAreaSyncException>().having(
          (error) => error.code,
          'code',
          'unavailable',
        ),
      ),
    );
  });

  test('duplicate response identifiers invalidate the whole read', () async {
    final admin = _Admin()
      ..readAreas = () async => const [
        HaArea(areaId: 'same', name: 'One'),
        HaArea(areaId: 'same', name: 'Two'),
      ];
    final reader = HaRoomAreaSyncReader(
      client: admin,
      serverUrl: 'http://ha.test',
      entities: () async => {},
      isCurrent: () => true,
    );
    await expectLater(
      reader.read(),
      throwsA(
        isA<RoomAreaSyncException>().having(
          (error) => error.code,
          'code',
          'invalid_data',
        ),
      ),
    );
  });

  test(
    'old-account result is discarded after the final asynchronous read',
    () async {
      final pending = Completer<List<HaArea>>();
      final admin = _Admin()..readAreas = () => pending.future;
      var current = true;
      final reader = HaRoomAreaSyncReader(
        client: admin,
        serverUrl: 'http://ha.test',
        entities: () async => {},
        isCurrent: () => current,
      );
      final result = reader.read();
      final rejected = expectLater(
        result,
        throwsA(
          isA<RoomAreaSyncException>().having(
            (error) => error.code,
            'code',
            'account_changed',
          ),
        ),
      );
      current = false;
      pending.complete(const [HaArea(areaId: 'salon', name: 'Salon')]);
      await rejected;
    },
  );
}
