import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/music_manager/data/server_music_command_receipt_cache.dart';
import 'package:larenor/features/server/music_manager/data/server_music_manager_controller.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_music_manager_test_support.dart';

final class _MemoryBackend implements ServerMusicCommandReceiptCacheBackend {
  String? value;
  int writes = 0, clears = 0;
  Completer<void>? readGate, writeGate;
  String? replacementBeforeClear;

  @override
  Future<String?> read() async {
    final captured = value;
    final gate = readGate;
    if (gate != null) await gate.future;
    return captured;
  }

  @override
  Future<bool> compareAndWrite(String? expected, String next) async {
    if (value != expected) return false;
    value = next;
    writes++;
    final gate = writeGate;
    if (gate != null) await gate.future;
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

const _scope = ServerMusicCommandReceiptScope(
  coreId: '11111111111111111111111111111111',
  homeId: '22222222222222222222222222222222',
  accountId: 'operator@example.test',
);

ServerMusicManager _manager({
  int revision = 7,
  String provider = 'airplay--main',
}) {
  final raw = musicManagerJson(revision: revision, playbackState: 'playing');
  final receiver = (raw['receivers'] as List).first as Map<String, dynamic>;
  receiver['provider'] = provider;
  return ServerMusicManager.fromJson(raw);
}

ServerMusicReceipt _receipt({
  int revision = 7,
  String state = 'succeeded',
  String code = 'authenticated_readback',
}) => ServerMusicReceipt.fromJson({
  'requestId': '33333333333333333333333333333333',
  'targetId': 'homepod-living',
  'operation': 'play',
  'state': state,
  'playerRevision': revision,
  'code': code,
  'installAvailable': false,
});

void main() {
  test(
    'SharedPreferences backend persists and exact-clears one receipt',
    () async {
      SharedPreferences.setMockInitialValues({});
      final writer = SharedPreferencesServerMusicCommandReceiptCacheBackend();
      expect(await writer.compareAndWrite(null, 'receipt'), isTrue);

      final reader = SharedPreferencesServerMusicCommandReceiptCacheBackend();
      expect(await reader.read(), 'receipt');
      expect(await reader.compareAndClear('other'), isFalse);
      expect(await reader.compareAndClear('receipt'), isTrue);
      expect(await writer.read(), isNull);
    },
  );

  test('binds exact tuple, manager, receiver, schema, TTL and quota', () async {
    final backend = _MemoryBackend();
    var now = DateTime.utc(2026, 9, 23, 13);
    final cache = ServerMusicCommandReceiptCache(
      backend: backend,
      now: () => now,
    );
    final manager = _manager();
    final receipt = _receipt();

    expect(
      await cache.write(_scope, manager, receipt, current: () => true),
      isTrue,
    );
    final raw = jsonDecode(backend.value!) as Map<String, dynamic>;
    expect(raw['schemaVersion'], 1);
    expect(backend.value, isNot(contains('accessToken')));
    expect(backend.value, isNot(contains('spotify://')));
    expect(await cache.read(_scope, manager, current: () => true), isNotNull);

    for (final other in const [
      ServerMusicCommandReceiptScope(
        coreId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        homeId: '22222222222222222222222222222222',
        accountId: 'operator@example.test',
      ),
      ServerMusicCommandReceiptScope(
        coreId: '11111111111111111111111111111111',
        homeId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        accountId: 'operator@example.test',
      ),
      ServerMusicCommandReceiptScope(
        coreId: '11111111111111111111111111111111',
        homeId: '22222222222222222222222222222222',
        accountId: 'other@example.test',
      ),
    ]) {
      expect(await cache.read(other, manager, current: () => true), isNull);
    }
    expect(
      await cache.read(_scope, _manager(revision: 8), current: () => true),
      isNull,
    );
    expect(
      await cache.read(
        _scope,
        _manager(provider: 'airplay--replacement'),
        current: () => true,
      ),
      isNull,
    );

    now = now.add(ServerMusicCommandReceiptCache.timeToLive);
    expect(await cache.read(_scope, manager, current: () => true), isNull);
    expect(backend.value, isNull);

    await expectLater(
      cache.write(
        _scope,
        manager,
        _receipt(state: 'needs_attention', code: 'effect_unknown'),
        current: () => true,
      ),
      throwsStateError,
    );
    backend.value = 'x' * (ServerMusicCommandReceiptCache.maximumBytes + 1);
    expect(await cache.read(_scope, manager, current: () => true), isNull);
    expect(backend.value, isNull);
  });

  test('strict parse clears only the exact malformed receipt owner', () async {
    final backend = _MemoryBackend();
    final cache = ServerMusicCommandReceiptCache(
      backend: backend,
      now: () => DateTime.utc(2026, 9, 23, 13),
    );
    await cache.write(_scope, _manager(), _receipt(), current: () => true);
    final valid = backend.value!;

    for (final mutate in <void Function(Map<String, dynamic>)>[
      (record) => record['schemaVersion'] = 1.0,
      (record) => record['unexpected'] = true,
      (record) =>
          (record['resource'] as Map<String, dynamic>)['managerRevision'] = 7.0,
      (record) =>
          (record['resource'] as Map<String, dynamic>)['installationRevision'] =
              0x8000000000000000,
      (record) =>
          (record['resource'] as Map<String, dynamic>)['targetId'] = 'bad id',
      (record) => (record['resource'] as Map<String, dynamic>)['groupMembers'] =
          ['bad member'],
      (record) => (record['receipt'] as Map<String, dynamic>)['token'] =
          'must-not-cross-cache-boundary',
    ]) {
      final record = jsonDecode(valid) as Map<String, dynamic>;
      mutate(record);
      backend.value = jsonEncode(record);
      final replacement = '$valid ';
      backend.replacementBeforeClear = replacement;

      expect(await cache.read(_scope, _manager(), current: () => true), isNull);
      expect(backend.value, replacement);
    }
  });

  test(
    'retired delayed read/write publishes nothing and preserves replacement',
    () async {
      final backend = _MemoryBackend();
      final cache = ServerMusicCommandReceiptCache(
        backend: backend,
        now: () => DateTime.utc(2026, 9, 23, 13),
      );
      await cache.write(_scope, _manager(), _receipt(), current: () => true);
      backend.readGate = Completer<void>();
      var current = true;
      final read = cache.read(_scope, _manager(), current: () => current);
      await Future<void>.delayed(Duration.zero);
      current = false;
      backend.readGate!.complete();
      expect(await read, isNull);

      backend.readGate = null;
      backend.value = null;
      backend.writeGate = Completer<void>();
      current = true;
      final write = cache.write(
        _scope,
        _manager(),
        _receipt(),
        current: () => current,
      );
      while (backend.value == null) {
        await Future<void>.delayed(Duration.zero);
      }
      final stale = backend.value!;
      current = false;
      backend.replacementBeforeClear = '$stale ';
      backend.writeGate!.complete();

      expect(await write, isFalse);
      expect(backend.value, '$stale ');
    },
  );

  test(
    'controller restores an authenticated receipt without replaying a command',
    () async {
      final backend = _MemoryBackend();
      final cache = ServerMusicCommandReceiptCache(
        backend: backend,
        now: () => DateTime.utc(2026, 9, 23, 13),
      );
      final fixture = MusicManagerFixture();
      await fixture.account.initialize();
      var request = 0;
      final first = ServerMusicManagerController(
        fixture.account,
        requestId: () => (++request).toRadixString(16).padLeft(32, '0'),
        receiptCache: cache,
      );
      await first.load(current: () => true);
      await first.verify(current: () => true);
      await first.command(ServerMusicOperation.play, current: () => true);
      expect(first.lastReceipt?.operation, 'play');
      expect(backend.value, isNotNull);
      first.dispose();
      final commands = fixture.calls
          .where((call) => call.url.path.endsWith('/manager/commands'))
          .length;

      final restarted = ServerMusicManagerController(
        fixture.account,
        requestId: () => (++request).toRadixString(16).padLeft(32, '0'),
        receiptCache: cache,
      );
      addTearDown(() {
        restarted.dispose();
        fixture.account.dispose();
      });
      await restarted.load(current: () => true);
      expect(restarted.lastReceipt, isNull);
      await restarted.verify(current: () => true);

      expect(restarted.lastReceipt?.operation, 'play');
      expect(restarted.lastReceipt?.authenticated, isTrue);
      expect(
        fixture.calls
            .where((call) => call.url.path.endsWith('/manager/commands'))
            .length,
        commands,
        reason: 'restoration is read-only and must never replay an effect',
      );
    },
  );
}
