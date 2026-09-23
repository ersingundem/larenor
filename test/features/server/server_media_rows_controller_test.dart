import 'dart:async';
import 'dart:convert' show jsonEncode;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/media_result_origin.dart';
import 'package:larenor/features/server/media_rows/data/server_media_rows_cache.dart';
import 'package:larenor/features/server/media_rows/data/server_media_rows_controller.dart';

import 'server_admin_test_support.dart';

const _requestId = '11111111111111111111111111111111';
const _installationId = '22222222222222222222222222222222';

Map<String, Object?> _target() => {
  'schemaVersion': 1,
  'installationId': _installationId,
  'installationRevision': 7,
  'snapshotRevision': 8,
  'jellyfinServiceRevision': 9,
};

Map<String, Object?> _rows({int revision = 10}) => {
  'requestId': _requestId,
  'installationId': _installationId,
  'installationRevision': 7,
  'bindingRevision': 4,
  'rows': {
    'schemaVersion': 1,
    'revision': revision,
    'recent': const [
      {
        'itemId': '33333333333333333333333333333333',
        'title': 'The Matrix',
        'mediaKind': 'movie',
        'addedAt': 2000000000,
        'runtimeSeconds': 8160,
        'positionSeconds': 0,
      },
    ],
    'resume': const [],
  },
};

final class _Fixture extends AdminFixture {
  _Fixture() {
    respond = (request) async {
      if (request.url.path.endsWith('/media/catalog/target')) {
        return json(_target());
      }
      if (request.url.path.endsWith('/media/rows/read')) {
        final gate = rowsGate;
        if (gate != null) return gate.future;
        return json(_rows(revision: revision));
      }
      return defaultResponse(request);
    };
  }

  int revision = 10;
  Completer<http.Response>? rowsGate;
}

void main() {
  test('refresh publishes live rows and account-scoped cache', () async {
    final fixture = _Fixture();
    await fixture.account.initialize();
    final cache = ServerMediaRowsCache();
    final first = ServerMediaRowsController(
      fixture.account,
      cache: cache,
      requestId: () => _requestId,
    );
    addTearDown(first.dispose);
    addTearDown(fixture.account.dispose);

    await first.refresh(current: () => true);
    expect(first.value?.rows.revision, 10);
    expect(first.origin, ServerMediaResultOrigin.live);

    fixture.revision = 11;
    fixture.rowsGate = Completer<http.Response>();
    final second = ServerMediaRowsController(
      fixture.account,
      cache: cache,
      requestId: () => _requestId,
    );
    addTearDown(second.dispose);
    final pending = second.refresh(current: () => true);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(second.value?.rows.revision, 10);
    expect(second.origin, ServerMediaResultOrigin.verifiedCache);
    fixture.rowsGate!.complete(fixture.json(_rows(revision: 11)));
    await pending;
    expect(second.value?.rows.revision, 11);
    expect(second.origin, ServerMediaResultOrigin.live);
  });

  test('logout retires delayed rows and evicts the account cache', () async {
    final fixture = _Fixture();
    await fixture.account.initialize();
    final cache = ServerMediaRowsCache();
    final controller = ServerMediaRowsController(
      fixture.account,
      cache: cache,
      requestId: () => _requestId,
    );
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    await controller.refresh(current: () => true);
    expect(controller.value, isNotNull);

    fixture.rowsGate = Completer<http.Response>();
    final pending = controller.refresh(current: () => true);
    await Future<void>.delayed(Duration.zero);
    await fixture.account.signOut();
    fixture.rowsGate!.complete(fixture.json(_rows(revision: 11)));
    await pending;
    expect(controller.value, isNull);
    expect(controller.failure, isNull);
    expect(controller.busy, isFalse);
  });

  test(
    'authority change clears cached rows but transport failure keeps them',
    () async {
      final fixture = _Fixture();
      await fixture.account.initialize();
      final controller = ServerMediaRowsController(
        fixture.account,
        cache: ServerMediaRowsCache(),
        requestId: () => _requestId,
      );
      addTearDown(controller.dispose);
      addTearDown(fixture.account.dispose);
      await controller.refresh(current: () => true);

      fixture.respond = (request) async {
        if (request.url.path.endsWith('/media/catalog/target')) {
          return fixture.json(_target());
        }
        return fixture.json({
          'error': {'code': 'media_rows_worker_unavailable'},
        }, 503);
      };
      await controller.refresh(current: () => true);
      expect(controller.failure, 'media_rows_worker_unavailable');
      expect(controller.value, isNotNull);

      fixture.respond = (request) async {
        if (request.url.path.endsWith('/media/catalog/target')) {
          return fixture.json(_target());
        }
        return fixture.json({
          'error': {'code': 'media_rows_authority_changed'},
        }, 409);
      };
      await controller.refresh(current: () => true);
      expect(controller.failure, 'media_rows_authority_changed');
      expect(controller.value, isNull);
    },
  );

  test('cache is bounded, expires and never crosses account scopes', () async {
    var now = DateTime.utc(2026, 9, 24, 12);
    final cache = ServerMediaRowsCache(now: () => now);
    final fixture = _Fixture();
    await fixture.account.initialize();
    final controller = ServerMediaRowsController(
      fixture.account,
      cache: cache,
      requestId: () => _requestId,
    );
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    await controller.refresh(current: () => true);
    now = now.add(ServerMediaRowsCache.timeToLive);

    fixture.rowsGate = Completer<http.Response>();
    final fresh = ServerMediaRowsController(
      fixture.account,
      cache: cache,
      requestId: () => _requestId,
    );
    addTearDown(fresh.dispose);
    final pending = fresh.refresh(current: () => true);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(fresh.value, isNull);
    fixture.rowsGate!.complete(
      http.Response(jsonEncode(_rows(revision: 12)), 200),
    );
    await pending;
  });
}
