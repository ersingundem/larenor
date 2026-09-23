import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/music_manager/data/server_music_manager_api.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';

import 'server_music_manager_test_support.dart';

Future<T> _withClient<T>(
  MusicManagerFixture fixture,
  Future<T> Function(ServerMusicManagerApi client) action,
) async {
  await fixture.account.initialize();
  return fixture.account.withSession(
    (api, session) => action(ServerMusicManagerApi(api, session.accessToken)),
  );
}

Matcher get _invalidRequest => isA<LarenorServerException>().having(
  (error) => error.code,
  'code',
  'invalid_request',
);

Matcher get _invalidResponse => isA<LarenorServerException>().having(
  (error) => error.code,
  'code',
  'invalid_response',
);

void main() {
  test('read and refresh bind the exact installation authority', () async {
    final fixture = MusicManagerFixture();
    addTearDown(fixture.account.dispose);
    final original = fixture.respond!;
    fixture.respond = (request) async {
      if (request.method == 'GET' && request.url.path.contains('/manager/')) {
        final manager = fixture.manager()..['installationId'] = 'b' * 32;
        return fixture.json({'manager': manager});
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/manager/refresh')) {
        final manager = fixture.manager()..['coreRevision'] = 3;
        return fixture.json({'manager': manager});
      }
      return original(request);
    };

    await expectLater(
      _withClient(fixture, (client) => client.read('a' * 32)),
      throwsA(_invalidResponse),
    );
    await expectLater(
      fixture.account.withSession(
        (api, session) =>
            ServerMusicManagerApi(api, session.accessToken).refresh(
              requestId: 'f' * 32,
              installationId: 'a' * 32,
              installationRevision: 4,
              coreRevision: 2,
            ),
      ),
      throwsA(_invalidResponse),
    );
  });

  test(
    'search rejects a foreign provider before network and binds its result',
    () async {
      final fixture = MusicManagerFixture();
      addTearDown(fixture.account.dispose);
      await fixture.account.initialize();
      final manager = ServerMusicManager.fromJson(fixture.manager());
      final foreignJson = fixture.manager();
      final foreignProvider =
          (foreignJson['providers'] as List).single as Map<String, dynamic>;
      foreignProvider['setupId'] = 'e' * 32;
      final foreign = ServerMusicManager.fromJson(foreignJson).providers.single;
      final before = fixture.calls.length;

      await expectLater(
        fixture.account.withSession(
          (api, session) =>
              ServerMusicManagerApi(api, session.accessToken).search(
                requestId: 'f' * 32,
                manager: manager,
                provider: foreign,
                query: 'Result',
              ),
        ),
        throwsA(_invalidRequest),
      );
      expect(fixture.calls, hasLength(before));

      final original = fixture.respond!;
      for (final corruption in ['request', 'revision', 'instance']) {
        fixture.respond = (request) async {
          if (request.url.path.endsWith('/manager/catalog/search')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return fixture.json({
              'catalog': {
                'requestId': corruption == 'request'
                    ? 'e' * 32
                    : body['requestId'],
                'managerRevision': corruption == 'revision'
                    ? manager.revision + 1
                    : manager.revision,
                'items': [
                  {
                    'uri': 'spotify://track/result',
                    'name': 'Result track',
                    'mediaType': 'track',
                    'providerInstanceId': corruption == 'instance'
                        ? 'spotify--foreign'
                        : manager.providers.single.instanceId,
                    'artists': ['Artist'],
                  },
                ],
              },
            });
          }
          return original(request);
        };
        await expectLater(
          fixture.account.withSession(
            (api, session) =>
                ServerMusicManagerApi(api, session.accessToken).search(
                  requestId: 'f' * 32,
                  manager: manager,
                  provider: manager.providers.single,
                  query: 'Result',
                ),
          ),
          throwsA(_invalidResponse),
          reason: corruption,
        );
      }
    },
  );

  test(
    'command rejects foreign or incapable receivers and binds the receipt',
    () async {
      final fixture = MusicManagerFixture();
      addTearDown(fixture.account.dispose);
      await fixture.account.initialize();
      final manager = ServerMusicManager.fromJson(fixture.manager());
      final foreignJson = fixture.manager();
      final foreignReceiver =
          (foreignJson['receivers'] as List).first as Map<String, dynamic>;
      foreignReceiver['playerId'] = 'homepod-foreign';
      final foreign = ServerMusicManager.fromJson(foreignJson).receivers.first;
      final forgedJson = fixture.manager();
      final forgedReceiver =
          (forgedJson['receivers'] as List)[1] as Map<String, dynamic>;
      forgedReceiver['capabilities'] = ['play', 'pause', 'seek', 'queue'];
      final forged = ServerMusicManager.fromJson(forgedJson).receivers[1];
      final before = fixture.calls.length;

      await expectLater(
        fixture.account.withSession(
          (api, session) =>
              ServerMusicManagerApi(api, session.accessToken).command(
                requestId: 'f' * 32,
                manager: manager,
                receiver: foreign,
                operation: ServerMusicOperation.play,
              ),
        ),
        throwsA(_invalidRequest),
      );
      await expectLater(
        fixture.account.withSession(
          (api, session) =>
              ServerMusicManagerApi(api, session.accessToken).command(
                requestId: 'f' * 32,
                manager: manager,
                receiver: manager.receivers[1],
                operation: ServerMusicOperation.queueClear,
              ),
        ),
        throwsA(_invalidRequest),
      );
      await expectLater(
        fixture.account.withSession(
          (api, session) =>
              ServerMusicManagerApi(api, session.accessToken).command(
                requestId: 'f' * 32,
                manager: manager,
                receiver: forged,
                operation: ServerMusicOperation.queueClear,
              ),
        ),
        throwsA(_invalidRequest),
      );
      expect(fixture.calls, hasLength(before));

      final original = fixture.respond!;
      fixture.respond = (request) async {
        if (request.url.path.endsWith('/manager/commands')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return fixture.json({
            'receipt': {
              'requestId': body['requestId'],
              'targetId': 'cast-kitchen',
              'operation': body['operation'],
              'state': 'succeeded',
              'playerRevision': manager.revision + 1,
              'code': 'authenticated_readback',
              'installAvailable': false,
            },
          }, 201);
        }
        return original(request);
      };
      await expectLater(
        fixture.account.withSession(
          (api, session) =>
              ServerMusicManagerApi(api, session.accessToken).command(
                requestId: 'f' * 32,
                manager: manager,
                receiver: manager.receivers.first,
                operation: ServerMusicOperation.play,
              ),
        ),
        throwsA(_invalidResponse),
      );
    },
  );
}
