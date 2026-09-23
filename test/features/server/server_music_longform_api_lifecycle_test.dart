import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/music_manager/data/server_music_manager_api.dart';
import 'package:larenor/features/server/music_manager/data/server_music_manager_controller.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';

import 'server_music_manager_test_support.dart';

Map<String, dynamic> _longform(String requestId, {int revision = 6}) => {
  'requestId': requestId,
  'managerRevision': revision,
  'items': [
    {
      'uri': 'library://audiobook/book-one',
      'name': 'Book one',
      'mediaType': 'audiobook',
      'providerInstanceId': 'spotify--fixture',
      'durationSeconds': 3600.0,
      'resumePositionSeconds': 900.0,
      'fullyPlayed': false,
      'chapters': [
        {
          'position': 0,
          'name': 'Opening',
          'startSeconds': 0.0,
          'endSeconds': 1200.0,
        },
      ],
    },
  ],
};

Matcher get _cancelled => isA<LarenorServerException>().having(
  (error) => error.code,
  'code',
  'cancelled',
);

Future<ServerMusicManagerController> _ready(MusicManagerFixture fixture) async {
  await fixture.account.initialize();
  var id = 0;
  final controller = ServerMusicManagerController(
    fixture.account,
    requestId: () => (++id).toRadixString(16).padLeft(32, '0'),
  );
  await controller.load(current: () => true);
  await controller.verify(current: () => true);
  return controller;
}

void main() {
  test(
    'API sends exact bounded authority body and accepts no URL metadata',
    () async {
      final fixture = MusicManagerFixture();
      addTearDown(fixture.account.dispose);
      await fixture.account.initialize();
      final manager = ServerMusicManager.fromJson(fixture.manager());
      fixture.respond = (request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body.keys.toSet(), {
          'requestId',
          'installationId',
          'expectedInstallationRevision',
          'expectedCoreRevision',
          'expectedManagerRevision',
          'limit',
        });
        expect(body['limit'], 25);
        expect(jsonEncode(body), isNot(contains('token')));
        expect(jsonEncode(body), isNot(contains('url')));
        return fixture.json({
          'longform': _longform(body['requestId'] as String),
        });
      };

      final result = await fixture.account.withSession(
        (api, session) =>
            ServerMusicManagerApi(api, session.accessToken).inProgress(
              requestId: 'f' * 32,
              manager: manager,
              limit: 25,
              current: () => true,
            ),
      );

      expect(result.items.single.name, 'Book one');
      expect(
        fixture.calls.last.url.path,
        endsWith('/manager/catalog/in-progress'),
      );
    },
  );

  test('throwing current callback fails closed before network', () async {
    final fixture = MusicManagerFixture();
    addTearDown(fixture.account.dispose);
    await fixture.account.initialize();
    final manager = ServerMusicManager.fromJson(fixture.manager());
    final before = fixture.calls.length;

    await expectLater(
      fixture.account.withSession(
        (api, session) =>
            ServerMusicManagerApi(api, session.accessToken).inProgress(
              requestId: 'f' * 32,
              manager: manager,
              limit: 25,
              current: () => throw StateError('retired route'),
            ),
      ),
      throwsA(_cancelled),
    );
    expect(fixture.calls, hasLength(before));
  });

  test('route drift after HTTP await never publishes stale longform', () async {
    final fixture = MusicManagerFixture();
    final controller = await _ready(fixture);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });
    final pending = Completer<http.Response>();
    final original = fixture.respond!;
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/manager/catalog/in-progress')) {
        return pending.future;
      }
      return original(request);
    };
    var current = true;
    final loading = controller.loadInProgress(current: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    pending.complete(
      fixture.json({'longform': _longform('3'.padLeft(32, '0'))}),
    );
    await loading;

    expect(controller.longform, isNull);
    expect(controller.longformFailure, isNull);
    expect(
      fixture.calls.where(
        (request) => request.url.path.endsWith('/manager/catalog/in-progress'),
      ),
      hasLength(1),
    );
  });

  test(
    'account retirement during HTTP await cannot publish or retry',
    () async {
      final fixture = MusicManagerFixture();
      final controller = await _ready(fixture);
      addTearDown(() {
        controller.dispose();
        fixture.account.dispose();
      });
      final pending = Completer<http.Response>();
      final original = fixture.respond!;
      fixture.respond = (request) async {
        if (request.url.path.endsWith('/manager/catalog/in-progress')) {
          return pending.future;
        }
        return original(request);
      };
      final loading = controller.loadInProgress(current: () => true);
      await Future<void>.delayed(Duration.zero);
      await fixture.account.signOut();
      pending.complete(
        fixture.json({'longform': _longform('3'.padLeft(32, '0'))}),
      );
      await loading;

      expect(controller.longform, isNull);
      expect(controller.longformBusy, false);
      expect(
        fixture.calls.where(
          (request) =>
              request.url.path.endsWith('/manager/catalog/in-progress'),
        ),
        hasLength(1),
      );
    },
  );

  test('manager reverify retires an older in-progress generation', () async {
    final fixture = MusicManagerFixture();
    final controller = await _ready(fixture);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });
    final pending = Completer<http.Response>();
    final original = fixture.respond!;
    var longformCalls = 0;
    String? oldRequestId;
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/manager/catalog/in-progress')) {
        longformCalls++;
        if (longformCalls == 1) {
          oldRequestId =
              (jsonDecode(request.body) as Map<String, dynamic>)['requestId']
                  as String;
          return pending.future;
        }
      }
      return original(request);
    };

    final older = controller.loadInProgress(current: () => true);
    await Future<void>.delayed(Duration.zero);
    await controller.verify(current: () => true);
    await controller.loadInProgress(current: () => true);
    expect(controller.longform?.items.single.name, 'Fixture audiobook');

    final stale = _longform(oldRequestId!);
    (stale['items'] as List).single['name'] = 'Stale private title';
    pending.complete(fixture.json({'longform': stale}));
    await older;

    expect(controller.longform?.items.single.name, 'Fixture audiobook');
    expect(longformCalls, 2);
  });
}
