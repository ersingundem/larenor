import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/music_retained/data/server_music_retained_controller.dart';
import 'package:larenor/features/server/music_retained/data/server_music_retained_cache.dart';
import 'package:larenor/features/server/music_retained/domain/server_music_retained_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'server_music_retained_status_test.dart' show retainedJson;
import 'server_music_retained_test_support.dart';

final class _RetainedMemoryBackend implements ServerMusicRetainedCacheBackend {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<bool> compareAndWrite(
    String? expected,
    String next, {
    required bool Function() current,
  }) async {
    if (!current() || value != expected) return false;
    value = next;
    return current();
  }

  @override
  Future<bool> compareAndClear(String expected) async {
    if (value != expected) return false;
    value = null;
    return true;
  }
}

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
    for (
      var attempt = 0;
      attempt < 20 && fixture.adminCalls.isEmpty;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
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

  test('publishes scoped cache before verified network refresh', () async {
    final fixture = MusicRetainedFixture();
    await fixture.account.initialize();
    final backend = _RetainedMemoryBackend();
    final cache = ServerMusicRetainedCache(
      backend: backend,
      now: () => fixture.now,
    );
    await cache.write(
      ServerMusicRetainedCacheScope.fromSession(fixture.account.session!),
      ServerMusicRetainedOverview.fromJson(retainedJson()),
      current: () => true,
    );
    final pending = Completer<http.Response>();
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/music-assistant/retained')) {
        return pending.future;
      }
      return fixture.defaultResponse(request);
    };
    final controller = ServerMusicRetainedController(
      fixture.account,
      cache: cache,
    );
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });

    final loading = controller.load(current: () => true);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.overview?.state, 'ready');
    expect(controller.stored, isTrue);
    expect(controller.reachable, isFalse);
    expect(controller.verified, isFalse);

    pending.complete(fixture.json(retainedJson()));
    await loading;
    expect(controller.reachable, isTrue);
    expect(controller.verified, isTrue);
  });
}
