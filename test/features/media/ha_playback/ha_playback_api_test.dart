import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/data/ha_api_exception.dart';
import 'package:larenor/features/media/ha_playback/data/ha_playback_api.dart';
import 'package:larenor/features/media/ha_playback/domain/ha_playback_models.dart';

import '../../ha_client/fake_socket.dart';
import 'ha_playback_fixture.dart';

void main() {
  late FakeSocket socket;
  late HaWebSocketClient client;
  late WsHaPlaybackApi api;
  var generation = 0;
  setUp(() async {
    generation = 0;
    socket = FakeSocket();
    client = HaWebSocketClient(
      baseUrl: 'https://ha.invalid',
      token: 'fixture-ha-auth',
      channelFactory: (_) => socket,
    );
    client.connect();
    await socket.authenticate();
    api = WsHaPlaybackApi(
      client,
      now: () => playbackNow,
      generation: () => generation,
    );
  });
  tearDown(() => client.dispose());
  Future<void> reply(String type, Object? result, {String? error}) async {
    await drain();
    expect(socket.sent.last['type'], type);
    socket.emit({
      'id': socket.sent.last['id'],
      'type': 'result',
      'success': error == null,
      if (error == null)
        'result': result
      else
        'error': {'code': error, 'message': 'secret backend details'},
    });
    await drain();
  }

  test('browse source WS shape and exact single-target MIME command do not resolve or share auth', () async {
    final browse = api.browse(null);
    await reply('media_source/browse_media', browseRaw());
    expect(socket.sent.last.keys.toSet(), {'type', 'id'});
    final page = await browse;
    final play = api.play(
      entityId: 'media_player.living',
      source: page.children.single,
      isCurrent: () => true,
    );
    await drain();
    final sent = {...socket.sent.last}..remove('id');
    expect(sent, {
      'type': 'call_service',
      'domain': 'media_player',
      'service': 'play_media',
      'target': {'entity_id': 'media_player.living'},
      'service_data': {
        'media_content_id': mediaSource,
        'media_content_type': 'audio/mpeg',
      },
    });
    expect(sent.toString(), isNot(contains('fixture-ha-auth')));
    await reply('call_service', {
      'context': {'id': 'accepted'},
    });
    await play;
    expect(
      socket.sent.where((row) => row['type'] == 'media_source/resolve_media'),
      isEmpty,
    );
  });
  test('inventory exact read commands, registry denial keeps readonly target plus issue', () async {
    final read = api.getInventory();
    await reply('get_states', [stateRaw()]);
    await reply('get_services', mediaServices);
    await reply('config/entity_registry/list', null, error: 'unauthorized');
    final value = await read;
    expect(value.registryAvailable, isFalse);
    expect(value.registryFailure, HaPlaybackFailure.permission);
    expect(value.targets, hasLength(1));
  });
  test(
    'service read failure is typed failure not no installed service',
    () async {
      final read = api.getInventory();
      final fails = expectLater(read, throwsA(isA<HaApiException>()));
      await reply('get_states', [stateRaw()]);
      await reply('get_services', null, error: 'unauthorized');
      await fails;
      expect(
        socket.sent.where(
          (row) => row['type'] == 'config/entity_registry/list',
        ),
        isEmpty,
      );
    },
  );
  test(
    'old read generation cannot continue after background then resume',
    () async {
      final read = api.getInventory();
      final fails = expectLater(read, throwsA(isA<HaPlaybackException>()));
      await drain();
      generation += 2;
      await reply('get_states', [stateRaw()]);
      await fails;
      expect(
        socket.sent.where((row) => row['type'] == 'get_services'),
        isEmpty,
      );
    },
  );
  test('wrong source parent and invalid source schema fail closed', () async {
    final read = api.browse('media-source://media_source');
    final fails = expectLater(read, throwsA(isA<HaPlaybackException>()));
    await reply('media_source/browse_media', browseRaw());
    await fails;
    final before = socket.sent.length;
    await expectLater(
      api.browse('https://receiver.invalid?token=fixture'),
      throwsA(isA<HaPlaybackException>()),
    );
    expect(socket.sent, hasLength(before));
  });
  test('connect wait checks lease before actual mutation dispatch', () async {
    client.dispose();
    socket = FakeSocket();
    client = HaWebSocketClient(
      baseUrl: 'https://ha.invalid',
      token: 'fixture',
      channelFactory: (_) => socket,
    );
    client.connect();
    var foreground = true;
    final pending = client.callService(
      'media_player',
      'play_media',
      target: {'entity_id': 'media_player.living'},
      serviceData: {
        'media_content_id': mediaSource,
        'media_content_type': 'audio/mpeg',
      },
      isCurrent: () => foreground,
    );
    final fails = expectLater(
      pending,
      throwsA(isA<HaApiException>().having((e) => e.code, 'code', 'cancelled')),
    );
    await socket.authenticate(acknowledgeSubscription: false);
    foreground = false;
    socket.emit({
      'id': socket.sent.last['id'],
      'type': 'result',
      'success': true,
    });
    await fails;
    expect(socket.sent.where((row) => row['type'] == 'call_service'), isEmpty);
  });
  test('unsupported raw target/source never goes on wire', () async {
    final source = parseHaMediaBrowse(browseRaw(), playbackNow).children.single;
    for (final target in [
      'all',
      'media_player.one,media_player.two',
      'light.one',
    ]) {
      await expectLater(
        api.play(entityId: target, source: source, isCurrent: () => true),
        throwsA(isA<HaPlaybackException>()),
      );
    }
    expect(socket.sent.where((row) => row['type'] == 'call_service'), isEmpty);
  });
  test(
    'wire failure classification is safe and distinguishes uncertainty causes',
    () {
      expect(
        haPlaybackFailure(HaApiException('private', code: 'auth_invalid')),
        HaPlaybackFailure.authentication,
      );
      expect(
        haPlaybackFailure(HaApiException('private', statusCode: 403)),
        HaPlaybackFailure.permission,
      );
      expect(
        haPlaybackFailure(TimeoutException('private')),
        HaPlaybackFailure.timeout,
      );
      expect(
        const HaPlaybackException(HaPlaybackFailure.transport).toString(),
        isNot(contains('private')),
      );
    },
  );
}
