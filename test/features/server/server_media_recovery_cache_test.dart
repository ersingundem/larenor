import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/media_recovery/data/server_media_recovery_cache.dart';
import 'package:larenor/features/server/media_recovery/data/server_media_recovery_controller.dart';
import 'package:larenor/features/server/media_recovery/domain/server_media_recovery_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_admin_test_support.dart';

Map<String, dynamic> _statusJson() => {
  'schemaVersion': 2,
  'state': 'incomplete',
  'installAvailable': false,
  'services': [
    for (var index = 0; index < mediaRecoveryServiceOrder.length; index++)
      if (index == 0)
        {
          'serviceId': 'larenor_core',
          'sourceId': 'a' * 32,
          'sourceKind': 'core',
          'revision': 1,
          'resultState': 'verified',
          'containerState': 'started',
          'serviceState': 'verified',
          'storedState': 'stored',
          'reachableState': 'reachable',
          'verifiedState': 'verified',
          'recoveryAction': 'none',
          'automaticRetry': false,
          'errorCode': null,
          'updatedAt': null,
        }
      else
        {
          'serviceId': mediaRecoveryServiceOrder[index],
          'sourceId': null,
          'sourceKind': 'missing',
          'revision': null,
          'resultState': 'missing',
          'containerState': 'unknown',
          'serviceState': 'unverified',
          'storedState': 'missing',
          'reachableState': 'unknown',
          'verifiedState': 'unverified',
          'recoveryAction': 'configure',
          'automaticRetry': false,
          'errorCode': null,
          'updatedAt': null,
        },
  ],
};

final class _MemoryBackend implements ServerMediaRecoveryCacheBackend {
  String? value;
  int writes = 0, clears = 0;
  Future<String?> Function()? readOverride;

  @override
  Future<String?> read() async =>
      readOverride == null ? value : await readOverride!();

  @override
  Future<bool> compareAndWrite(
    String? expected,
    String next, {
    required bool Function() current,
  }) async {
    if (!current() || value != expected) return false;
    writes++;
    value = next;
    return current();
  }

  @override
  Future<bool> compareAndClear(String expected) async {
    if (value != expected) return false;
    clears++;
    value = null;
    return true;
  }
}

final class _DelayedWriteBackend implements ServerMediaRecoveryCacheBackend {
  String? value;
  final written = Completer<void>();
  final release = Completer<void>();

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
    written.complete();
    await release.future;
    return true;
  }

  @override
  Future<bool> compareAndClear(String expected) async {
    if (value != expected) return false;
    value = null;
    return true;
  }
}

const _scope = ServerMediaRecoveryCacheScope(
  coreId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  homeId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  accountId: adminId,
);

void main() {
  test('SharedPreferences backend survives a fresh cache backend', () async {
    SharedPreferences.setMockInitialValues({});
    final writer = SharedPreferencesServerMediaRecoveryCacheBackend();
    expect(
      await writer.compareAndWrite(null, 'snapshot', current: () => true),
      isTrue,
    );
    final reader = SharedPreferencesServerMediaRecoveryCacheBackend();
    expect(await reader.read(), 'snapshot');
    expect(await reader.compareAndClear('other'), isFalse);
    expect(await reader.read(), 'snapshot');
    expect(await reader.compareAndClear('snapshot'), isTrue);
    expect(await writer.read(), isNull);
  });

  test(
    'cache binds exact scope, resource vector, schema, TTL and quota',
    () async {
      final backend = _MemoryBackend();
      var now = DateTime.utc(2026, 9, 23, 10);
      final cache = ServerMediaRecoveryCache(backend: backend, now: () => now);
      final status = ServerMediaRecoveryStatus.fromJson(_statusJson());

      expect(await cache.write(_scope, status, current: () => true), isTrue);
      expect(await cache.read(_scope, current: () => true), isNotNull);
      expect(backend.value, isNot(contains('token')));
      expect(backend.value, isNot(contains('password')));
      final envelope = jsonDecode(backend.value!) as Map<String, dynamic>;
      expect(envelope['schemaVersion'], 1);
      expect((envelope['resource'] as Map)['kind'], 'media_recovery_status');

      for (final other in const [
        ServerMediaRecoveryCacheScope(
          coreId: 'cccccccccccccccccccccccccccccccc',
          homeId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          accountId: adminId,
        ),
        ServerMediaRecoveryCacheScope(
          coreId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          homeId: 'cccccccccccccccccccccccccccccccc',
          accountId: adminId,
        ),
        ServerMediaRecoveryCacheScope(
          coreId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          homeId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          accountId: memberId,
        ),
      ]) {
        expect(await cache.read(other, current: () => true), isNull);
      }

      final corrupt = jsonDecode(backend.value!) as Map<String, dynamic>;
      final vector =
          (corrupt['resource'] as Map<String, dynamic>)['revisionVector']
              as List;
      (vector.first as Map<String, dynamic>)['revision'] = 2;
      backend.value = jsonEncode(corrupt);
      expect(await cache.read(_scope, current: () => true), isNull);
      expect(backend.value, isNull);

      expect(await cache.write(_scope, status, current: () => true), isTrue);
      now = now.add(ServerMediaRecoveryCache.timeToLive);
      expect(await cache.read(_scope, current: () => true), isNull);

      backend.value = 'x' * (ServerMediaRecoveryCache.maximumBytes + 1);
      expect(await cache.read(_scope, current: () => true), isNull);
      expect(backend.value, isNull);
    },
  );

  test('retired write cannot erase a replacement owner record', () async {
    final backend = _DelayedWriteBackend();
    final cache = ServerMediaRecoveryCache(
      backend: backend,
      now: () => DateTime.utc(2026, 9, 23, 10),
    );
    var current = true;
    final pending = cache.write(
      _scope,
      ServerMediaRecoveryStatus.fromJson(_statusJson()),
      current: () => current,
    );
    await backend.written.future;
    current = false;
    backend.value = 'replacement-owner';
    backend.release.complete();

    expect(await pending, isFalse);
    expect(backend.value, 'replacement-owner');
  });

  test('controller restores scoped cache only while route remains current', () async {
    final backend = _MemoryBackend();
    final cache = ServerMediaRecoveryCache(
      backend: backend,
      now: () => DateTime.utc(2026, 9, 23, 10),
    );
    final fixture = AdminFixture();
    fixture.respond = (request) async =>
        request.url.path.endsWith('/admin/media/recovery-status')
        ? fixture.json(_statusJson())
        : fixture.defaultResponse(request);
    await fixture.account.initialize();
    final first = ServerMediaRecoveryController(fixture.account, cache: cache);
    await first.load(current: () => true);
    expect(first.status, isNotNull);
    expect(first.cached, isFalse);
    expect(backend.writes, 1);
    first.dispose();

    fixture.respond = (request) async =>
        request.url.path.endsWith('/admin/media/recovery-status')
        ? fixture.json({
            'error': {'code': 'server_error'},
          }, 500)
        : fixture.defaultResponse(request);
    final restarted = ServerMediaRecoveryController(
      fixture.account,
      cache: ServerMediaRecoveryCache(
        backend: backend,
        now: () => DateTime.utc(2026, 9, 23, 10, 1),
      ),
    );
    addTearDown(() {
      restarted.dispose();
      fixture.account.dispose();
    });
    await restarted.load(current: () => true);
    expect(restarted.status, isNotNull);
    expect(restarted.cached, isTrue);
    expect(restarted.failure, 'server_error');

    restarted.invalidate();
    var current = true;
    final delayed = Completer<void>();
    // A route retirement after cache I/O must suppress both cached publication
    // and the following network request.
    backend.readOverride = () async {
      await delayed.future;
      return backend.value;
    };
    final readsBefore = fixture.calls
        .where((request) => request.url.path.endsWith('/recovery-status'))
        .length;
    final pending = restarted.load(current: () => current);
    current = false;
    delayed.complete();
    await pending;
    expect(restarted.status, isNull);
    expect(
      fixture.calls
          .where((request) => request.url.path.endsWith('/recovery-status'))
          .length,
      readsBefore,
    );
  });
}
