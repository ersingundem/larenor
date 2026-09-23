import 'dart:async';

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

Map<String, Object?> _rows({int revision = 10, int bindingRevision = 4}) => {
  'requestId': _requestId,
  'installationId': _installationId,
  'installationRevision': 7,
  'bindingRevision': bindingRevision,
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
      if (request.url.path.endsWith('/media/rows/target')) {
        return json({
          'schemaVersion': 1,
          'installationId': _installationId,
          'installationRevision': 7,
          'bindingRevision': bindingRevision,
        });
      }
      if (request.url.path.endsWith('/media/rows/read')) {
        final gate = rowsGate;
        if (gate != null) return gate.future;
        return json(
          _rows(revision: revision, bindingRevision: bindingRevision),
        );
      }
      return defaultResponse(request);
    };
  }

  int revision = 10;
  int bindingRevision = 4;
  Completer<http.Response>? rowsGate;
}

final class _RowsBackend implements ServerMediaRowsCacheBackend {
  String? value;
  Completer<void>? readGate, writeGate;

  @override
  Future<String?> read() async {
    final captured = value;
    final gate = readGate;
    if (gate != null) await gate.future;
    return captured;
  }

  @override
  Future<bool> compareAndWrite(
    String? expected,
    String next, {
    required bool Function() current,
  }) async {
    if (!current() || value != expected) return false;
    value = next;
    final gate = writeGate;
    if (gate != null) await gate.future;
    if (!current()) {
      if (value == next) value = null;
      return false;
    }
    return true;
  }

  @override
  Future<bool> compareAndClear(String expected) async {
    if (value != expected) return false;
    value = null;
    return true;
  }
}

void main() {
  test(
    'restart publishes cache only after a fresh target then revalidates live',
    () async {
      final backend = _RowsBackend();
      final cache = ServerMediaRowsCache(
        backend: backend,
        now: () => DateTime.utc(2026, 9, 24, 12),
      );
      final writerFixture = _Fixture();
      await writerFixture.account.initialize();
      final writer = ServerMediaRowsController(
        writerFixture.account,
        cache: cache,
        requestId: () => _requestId,
      );
      await writer.refresh(current: () => true);
      expect(writer.origin, ServerMediaResultOrigin.live);
      writer.dispose();
      writerFixture.account.dispose();

      final readerFixture = _Fixture()
        ..revision = 11
        ..rowsGate = Completer<http.Response>();
      await readerFixture.account.initialize();
      final reader = ServerMediaRowsController(
        readerFixture.account,
        cache: ServerMediaRowsCache(
          backend: backend,
          now: () => DateTime.utc(2026, 9, 24, 12),
        ),
        requestId: () => _requestId,
      );
      addTearDown(reader.dispose);
      addTearDown(readerFixture.account.dispose);

      final pending = reader.refresh(current: () => true);
      for (var turn = 0; turn < 12 && reader.value == null; turn++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        readerFixture.calls.map((call) => call.url.path),
        containsAllInOrder([
          '/prefix/api/v1/media/catalog/target',
          '/prefix/api/v1/media/rows/target',
        ]),
      );
      expect(reader.value?.rows.revision, 10);
      expect(reader.origin, ServerMediaResultOrigin.verifiedCache);
      expect(reader.busy, isTrue);

      readerFixture.rowsGate!.complete(readerFixture.json(_rows(revision: 11)));
      await pending;
      expect(reader.value?.rows.revision, 11);
      expect(reader.origin, ServerMediaResultOrigin.live);
    },
  );

  test('fresh binding B never publishes cached binding A', () async {
    final backend = _RowsBackend();
    final now = DateTime.utc(2026, 9, 24, 12);
    final first = _Fixture();
    await first.account.initialize();
    final writer = ServerMediaRowsController(
      first.account,
      cache: ServerMediaRowsCache(backend: backend, now: () => now),
      requestId: () => _requestId,
    );
    await writer.refresh(current: () => true);
    writer.dispose();
    first.account.dispose();

    final second = _Fixture()
      ..bindingRevision = 5
      ..revision = 12
      ..rowsGate = Completer<http.Response>();
    await second.account.initialize();
    final reader = ServerMediaRowsController(
      second.account,
      cache: ServerMediaRowsCache(backend: backend, now: () => now),
      requestId: () => _requestId,
    );
    addTearDown(reader.dispose);
    addTearDown(second.account.dispose);

    final pending = reader.refresh(current: () => true);
    for (var turn = 0; turn < 12; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(reader.value, isNull);
    expect(reader.origin, isNull);
    second.rowsGate!.complete(
      second.json(_rows(revision: 12, bindingRevision: 5)),
    );
    await pending;
    expect(reader.value?.bindingRevision, 5);
    expect(reader.origin, ServerMediaResultOrigin.live);
  });

  test(
    'retirement during persistent cache read publishes no stale rows',
    () async {
      final backend = _RowsBackend();
      final cache = ServerMediaRowsCache(
        backend: backend,
        now: () => DateTime.utc(2026, 9, 24, 12),
      );
      final first = _Fixture();
      await first.account.initialize();
      final writer = ServerMediaRowsController(
        first.account,
        cache: cache,
        requestId: () => _requestId,
      );
      await writer.refresh(current: () => true);
      writer.dispose();
      first.account.dispose();

      backend.readGate = Completer<void>();
      final second = _Fixture();
      await second.account.initialize();
      final reader = ServerMediaRowsController(
        second.account,
        cache: cache,
        requestId: () => _requestId,
      );
      addTearDown(reader.dispose);
      addTearDown(second.account.dispose);
      var current = true;
      final pending = reader.refresh(current: () => current);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      current = false;
      reader.retire();
      backend.readGate!.complete();
      await pending;
      expect(reader.value, isNull);
      expect(reader.origin, isNull);
      expect(reader.busy, isFalse);
    },
  );

  test(
    'retirement during cache write publishes no live or cached rows',
    () async {
      final backend = _RowsBackend()..writeGate = Completer<void>();
      final fixture = _Fixture();
      await fixture.account.initialize();
      final controller = ServerMediaRowsController(
        fixture.account,
        cache: ServerMediaRowsCache(
          backend: backend,
          now: () => DateTime.utc(2026, 9, 24, 12),
        ),
        requestId: () => _requestId,
      );
      addTearDown(controller.dispose);
      addTearDown(fixture.account.dispose);
      var current = true;
      final pending = controller.refresh(current: () => current);
      while (backend.value == null) {
        await Future<void>.delayed(Duration.zero);
      }
      current = false;
      controller.retire();
      backend.writeGate!.complete();
      await pending;
      expect(controller.value, isNull);
      expect(controller.origin, isNull);
      expect(controller.busy, isFalse);
      expect(backend.value, isNull);
    },
  );

  test(
    'refresh publishes only live rows and clears while revalidating',
    () async {
      final fixture = _Fixture();
      await fixture.account.initialize();
      final controller = ServerMediaRowsController(
        fixture.account,
        requestId: () => _requestId,
      );
      addTearDown(controller.dispose);
      addTearDown(fixture.account.dispose);

      await controller.refresh(current: () => true);
      expect(controller.value?.rows.revision, 10);
      expect(controller.origin, ServerMediaResultOrigin.live);

      fixture.revision = 11;
      fixture.rowsGate = Completer<http.Response>();
      final pending = controller.refresh(current: () => true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(controller.value, isNull);
      expect(controller.origin, isNull);
      fixture.rowsGate!.complete(fixture.json(_rows(revision: 11)));
      await pending;
      expect(controller.value?.rows.revision, 11);
      expect(controller.origin, ServerMediaResultOrigin.live);
    },
  );

  test('logout retires delayed rows', () async {
    final fixture = _Fixture();
    await fixture.account.initialize();
    final controller = ServerMediaRowsController(
      fixture.account,
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

  test('authority and worker failures never retain old rows', () async {
    final fixture = _Fixture();
    await fixture.account.initialize();
    final controller = ServerMediaRowsController(
      fixture.account,
      requestId: () => _requestId,
    );
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    await controller.refresh(current: () => true);

    fixture.respond = (request) async {
      if (request.url.path.endsWith('/media/catalog/target')) {
        return fixture.json(_target());
      }
      if (request.url.path.endsWith('/media/rows/target')) {
        return fixture.json({
          'schemaVersion': 1,
          'installationId': _installationId,
          'installationRevision': 7,
          'bindingRevision': 4,
        });
      }
      return fixture.json({
        'error': {'code': 'media_rows_worker_unavailable'},
      }, 503);
    };
    await controller.refresh(current: () => true);
    expect(controller.failure, 'media_rows_worker_unavailable');
    expect(controller.value, isNull);

    fixture.respond = (request) async {
      if (request.url.path.endsWith('/media/catalog/target')) {
        return fixture.json(_target());
      }
      if (request.url.path.endsWith('/media/rows/target')) {
        return fixture.json({
          'schemaVersion': 1,
          'installationId': _installationId,
          'installationRevision': 7,
          'bindingRevision': 4,
        });
      }
      return fixture.json({
        'error': {'code': 'media_rows_authority_changed'},
      }, 409);
    };
    await controller.refresh(current: () => true);
    expect(controller.failure, 'media_rows_authority_changed');
    expect(controller.value, isNull);
  });

  test('route retirement discards a valid delayed response', () async {
    final fixture = _Fixture();
    await fixture.account.initialize();
    final controller = ServerMediaRowsController(
      fixture.account,
      requestId: () => _requestId,
    );
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    fixture.rowsGate = Completer<http.Response>();
    var current = true;
    final pending = controller.refresh(current: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    fixture.rowsGate!.complete(fixture.json(_rows(revision: 12)));
    await pending;
    expect(controller.value, isNull);
    expect(controller.failure, isNull);
  });
}
