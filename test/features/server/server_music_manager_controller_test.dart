import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/music_manager/data/server_music_manager_controller.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';

import 'server_music_manager_test_support.dart';

void main() {
  Future<ServerMusicManagerController> ready(
    MusicManagerFixture fixture,
  ) async {
    await fixture.account.initialize();
    var id = 0;
    final controller = ServerMusicManagerController(
      fixture.account,
      requestId: () => (++id).toRadixString(16).padLeft(32, '0'),
    );
    await controller.load(current: () => true);
    expect(controller.stored, true);
    expect(controller.reachable, true);
    expect(controller.verified, false);
    await controller.verify(current: () => true);
    expect(controller.verified, true);
    return controller;
  }

  test('stored, reachable and verified are separate evidence states', () async {
    final fixture = MusicManagerFixture();
    await fixture.account.initialize();
    final pending = Completer<http.Response>();
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/music-assistant/retained')) {
        return fixture.response(request);
      }
      if (request.method == 'GET' && request.url.path.contains('/manager/')) {
        return pending.future;
      }
      return fixture.defaultResponse(request);
    };
    final controller = ServerMusicManagerController(fixture.account);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });

    final loading = controller.load(current: () => true);
    await Future<void>.delayed(Duration.zero);
    expect(controller.stored, true);
    expect(controller.reachable, false);
    expect(controller.verified, false);
    pending.complete(fixture.json({'manager': fixture.manager()}));
    await loading;
    expect(controller.reachable, true);
    expect(controller.verified, false);
  });

  test('secret-bearing manager wrapper is rejected before exposure', () async {
    final fixture = MusicManagerFixture();
    final original = fixture.respond!;
    fixture.respond = (request) async {
      if (request.method == 'GET' &&
          request.url.path.contains('/music-assistant/manager/')) {
        return fixture.json({
          'manager': fixture.manager(),
          'token': 'must-not-be-public',
        });
      }
      return original(request);
    };
    await fixture.account.initialize();
    final controller = ServerMusicManagerController(fixture.account);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });

    await controller.load(current: () => true);

    expect(controller.stored, true);
    expect(controller.reachable, false);
    expect(controller.verified, false);
    expect(controller.manager, isNull);
    expect(controller.failure, 'invalid_response');
  });

  test(
    'catalog search binds provider and manager revisions without secrets',
    () async {
      final fixture = MusicManagerFixture();
      final controller = await ready(fixture);
      addTearDown(() {
        controller.dispose();
        fixture.account.dispose();
      });

      await controller.search(' Result ', current: () => true);

      expect(controller.catalog?.items.single.name, 'Result track');
      final request = fixture.calls.lastWhere(
        (item) => item.url.path.endsWith('/manager/catalog/search'),
      );
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['expectedManagerRevision'], 6);
      expect(body['expectedProviderRevision'], 3);
      expect(body['query'], 'Result');
      expect(jsonEncode(body).toLowerCase(), isNot(contains('token')));
      expect(jsonEncode(body).toLowerCase(), isNot(contains('password')));
    },
  );

  for (final operation in ServerMusicOperation.values) {
    test(
      '${operation.wire} requires receipt and matching fresh readback',
      () async {
        final fixture = MusicManagerFixture();
        final controller = await ready(fixture);
        addTearDown(() {
          controller.dispose();
          fixture.account.dispose();
        });
        if ({
          ServerMusicOperation.queueAdd,
          ServerMusicOperation.queueReplace,
        }.contains(operation)) {
          await controller.search('Result', current: () => true);
          controller.selectMedia('spotify://track/result');
        }

        await controller.command(
          operation,
          positionSeconds: operation == ServerMusicOperation.seek ? 35 : null,
          current: () => true,
        );

        expect(controller.failure, isNull);
        expect(controller.verified, true);
        expect(controller.manager?.revision, 7);
        final writes = fixture.calls.where(
          (item) => item.url.path.endsWith('/manager/commands'),
        );
        expect(writes, hasLength(1));
        final commandIndex = fixture.calls.indexOf(writes.single);
        expect(
          fixture.calls
              .skip(commandIndex + 1)
              .any(
                (item) =>
                    item.method == 'GET' && item.url.path.contains('/manager/'),
              ),
          true,
        );
      },
    );
  }

  test('receipt without matching manager readback fails closed', () async {
    final fixture = MusicManagerFixture();
    final controller = await ready(fixture);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });
    var commandSeen = false;
    final original = fixture.respond!;
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/manager/commands')) {
        commandSeen = true;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return fixture.json({
          'receipt': {
            'requestId': body['requestId'],
            'targetId': body['targetId'],
            'operation': body['operation'],
            'state': 'succeeded',
            'playerRevision': 99,
            'code': 'authenticated_readback',
            'installAvailable': false,
          },
        }, 201);
      }
      return original(request);
    };

    await controller.command(ServerMusicOperation.play, current: () => true);

    expect(commandSeen, true);
    expect(controller.verified, false);
    expect(controller.failure, 'effect_unknown');
    expect(controller.manager?.revision, 6);
  });

  test('late route result is discarded and never retried', () async {
    final fixture = MusicManagerFixture();
    final controller = await ready(fixture);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });
    final pending = Completer<http.Response>();
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/manager/catalog/search')) {
        return pending.future;
      }
      return fixture.response(request);
    };
    var current = true;
    final search = controller.search('Result', current: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    pending.complete(
      fixture.json({
        'catalog': {
          'requestId': '3'.padLeft(32, '0'),
          'managerRevision': 6,
          'items': <Object>[],
        },
      }),
    );
    await search;

    expect(controller.catalog, isNull);
    expect(
      fixture.calls.where(
        (item) => item.url.path.endsWith('/manager/catalog/search'),
      ),
      hasLength(1),
    );
  });
}
