import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/media_rows/data/server_media_rows_cache.dart';
import 'package:larenor/features/server/media_rows/domain/server_media_rows_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _MemoryBackend implements ServerMediaRowsCacheBackend {
  String? value;
  Completer<void>? readGate, writeGate;
  String? replacementBeforeClear;
  int clears = 0;

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
      await compareAndClear(next);
      return false;
    }
    return true;
  }

  @override
  Future<bool> compareAndClear(String expected) async {
    final replacement = replacementBeforeClear;
    replacementBeforeClear = null;
    if (replacement != null) value = replacement;
    if (value != expected) return false;
    value = null;
    clears++;
    return true;
  }
}

const _scope = ServerMediaRowsCacheScope(
  coreId: '11111111111111111111111111111111',
  homeId: '22222222222222222222222222222222',
  accountId: 'operator@example.test',
);
const _installationId = '33333333333333333333333333333333';
const _requestId = '44444444444444444444444444444444';

ServerMediaRowsTarget _target({
  int installationRevision = 7,
  int binding = 4,
}) => ServerMediaRowsTarget.fromJson(
  {
    'schemaVersion': 1,
    'installationId': _installationId,
    'installationRevision': installationRevision,
    'bindingRevision': binding,
  },
  expectedInstallationId: _installationId,
  expectedInstallationRevision: installationRevision,
);

Map<String, Object?> _valueJson({
  int installationRevision = 7,
  int binding = 4,
  int rowsRevision = 10,
}) => {
  'requestId': _requestId,
  'installationId': _installationId,
  'installationRevision': installationRevision,
  'bindingRevision': binding,
  'rows': {
    'schemaVersion': 1,
    'revision': rowsRevision,
    'recent': const [
      {
        'itemId': '55555555555555555555555555555555',
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

ServerAccountMediaRows _value({
  int installationRevision = 7,
  int binding = 4,
  int rowsRevision = 10,
}) => ServerAccountMediaRows.fromJson(
  _valueJson(
    installationRevision: installationRevision,
    binding: binding,
    rowsRevision: rowsRevision,
  ),
  expectedRequestId: _requestId,
  expectedInstallationId: _installationId,
  expectedInstallationRevision: installationRevision,
  expectedBindingRevision: binding,
);

void main() {
  test('SharedPreferences backend survives a fresh cache instance', () async {
    SharedPreferences.setMockInitialValues({});
    final writer = SharedPreferencesServerMediaRowsCacheBackend();
    expect(
      await writer.compareAndWrite(null, 'snapshot', current: () => true),
      isTrue,
    );

    final reader = SharedPreferencesServerMediaRowsCacheBackend();
    expect(await reader.read(), 'snapshot');
    expect(await reader.compareAndClear('snapshot'), isTrue);
    expect(await writer.read(), isNull);
  });

  test('binds exact scope and installation plus binding authority', () async {
    final backend = _MemoryBackend();
    final cache = ServerMediaRowsCache(
      backend: backend,
      now: () => DateTime.utc(2026, 9, 24, 12),
    );
    expect(
      await cache.write(_scope, _target(), _value(), current: () => true),
      isTrue,
    );
    final record = jsonDecode(backend.value!) as Map<String, dynamic>;
    expect(record.keys.toSet(), {
      'schemaVersion',
      'scope',
      'resource',
      'savedAt',
      'rows',
    });
    expect(backend.value, isNot(contains(_requestId)));
    expect(backend.value, isNot(contains('accessToken')));
    expect(backend.value, isNot(contains('apiKey')));
    expect(
      (await cache.read(_scope, _target(), current: () => true))?.rows.revision,
      10,
    );

    for (final otherScope in const [
      ServerMediaRowsCacheScope(
        coreId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        homeId: '22222222222222222222222222222222',
        accountId: 'operator@example.test',
      ),
      ServerMediaRowsCacheScope(
        coreId: '11111111111111111111111111111111',
        homeId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        accountId: 'operator@example.test',
      ),
      ServerMediaRowsCacheScope(
        coreId: '11111111111111111111111111111111',
        homeId: '22222222222222222222222222222222',
        accountId: 'other@example.test',
      ),
    ]) {
      expect(
        await cache.read(otherScope, _target(), current: () => true),
        isNull,
      );
    }
    expect(
      await cache.read(
        _scope,
        _target(installationRevision: 8),
        current: () => true,
      ),
      isNull,
    );
    expect(
      await cache.read(_scope, _target(binding: 5), current: () => true),
      isNull,
    );
  });

  test('malformed and expired exact owners fail closed', () async {
    final backend = _MemoryBackend();
    var now = DateTime.utc(2026, 9, 24, 12);
    final cache = ServerMediaRowsCache(backend: backend, now: () => now);
    await cache.write(_scope, _target(), _value(), current: () => true);
    final valid = backend.value!;

    for (final mutate in <void Function(Map<String, dynamic>)>[
      (record) => record['schemaVersion'] = 1.0,
      (record) => record['apiKey'] = 'must-not-cross-cache-boundary',
      (record) =>
          (record['resource'] as Map<String, dynamic>)['bindingRevision'] = 4.0,
      (record) => (record['rows'] as Map<String, dynamic>)['revision'] = true,
    ]) {
      final record = jsonDecode(valid) as Map<String, dynamic>;
      mutate(record);
      backend.value = jsonEncode(record);
      final replacement = '$valid ';
      backend.replacementBeforeClear = replacement;
      expect(await cache.read(_scope, _target(), current: () => true), isNull);
      expect(backend.value, replacement);
    }

    backend.value = valid;
    now = now.add(ServerMediaRowsCache.timeToLive);
    expect(await cache.read(_scope, _target(), current: () => true), isNull);
    expect(backend.value, isNull);

    backend.value = List.filled(
      ServerMediaRowsCache.maximumBytes + 1,
      'x',
    ).join();
    expect(await cache.read(_scope, _target(), current: () => true), isNull);
    expect(backend.value, isNull);
  });

  test('retirement during delayed read returns no cached rows', () async {
    final backend = _MemoryBackend();
    final cache = ServerMediaRowsCache(
      backend: backend,
      now: () => DateTime.utc(2026, 9, 24, 12),
    );
    await cache.write(_scope, _target(), _value(), current: () => true);
    backend.readGate = Completer<void>();
    var current = true;

    final pending = cache.read(_scope, _target(), current: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    backend.readGate!.complete();
    expect(await pending, isNull);
  });

  test('retirement during write removes only its exact stale value', () async {
    for (final replacementWins in [false, true]) {
      final backend = _MemoryBackend()..writeGate = Completer<void>();
      final cache = ServerMediaRowsCache(
        backend: backend,
        now: () => DateTime.utc(2026, 9, 24, 12),
      );
      var current = true;
      final pending = cache.write(
        _scope,
        _target(),
        _value(),
        current: () => current,
      );
      while (backend.value == null) {
        await Future<void>.delayed(Duration.zero);
      }
      final stale = backend.value!;
      current = false;
      if (replacementWins) backend.replacementBeforeClear = '$stale ';
      backend.writeGate!.complete();

      expect(await pending, isFalse);
      expect(backend.value, replacementWins ? '$stale ' : null);
    }
  });
}
