import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/music_retained/data/server_music_retained_controller.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'server_music_retained_status_test.dart' show retainedJson;
import 'server_music_retained_test_support.dart';

void main() {
  test('member account cannot issue retained inventory requests', () async {
    final fixture = MusicRetainedFixture(role: ServerRole.member);
    await fixture.account.initialize();
    final controller = ServerMusicRetainedController(fixture.account);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });

    await controller.load(current: () => true);

    expect(fixture.adminCalls, isEmpty);
    expect(controller.overview, isNull);
    expect(controller.busy, isFalse);
  });

  test('double refresh keeps one read in flight', () async {
    final fixture = MusicRetainedFixture();
    await fixture.account.initialize();
    final pending = Completer<http.Response>();
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/music-assistant/retained')) {
        return pending.future;
      }
      return fixture.defaultResponse(request);
    };
    final controller = ServerMusicRetainedController(fixture.account);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });

    final first = controller.load(current: () => true);
    await Future<void>.delayed(Duration.zero);
    await controller.load(current: () => true);
    expect(
      fixture.adminCalls.where(
        (call) => call.url.path.endsWith('/music-assistant/retained'),
      ),
      hasLength(1),
    );

    pending.complete(fixture.json(retainedJson()));
    await first;
    expect(controller.overview?.state, 'ready');
  });

  test('late route result and later sign-out clear retained state', () async {
    final fixture = MusicRetainedFixture();
    await fixture.account.initialize();
    final pending = Completer<http.Response>();
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/music-assistant/retained')) {
        return pending.future;
      }
      return fixture.defaultResponse(request);
    };
    final controller = ServerMusicRetainedController(fixture.account);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });
    var current = true;
    final load = controller.load(current: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    pending.complete(fixture.json(retainedJson()));
    await load;
    expect(controller.overview, isNull);

    current = true;
    fixture.respond = (request) async => fixture.retainedResponse(request);
    await controller.load(current: () => current);
    expect(controller.overview?.state, 'ready');
    await fixture.account.signOut();
    expect(controller.overview, isNull);
  });
}
