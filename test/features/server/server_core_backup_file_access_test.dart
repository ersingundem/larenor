import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/core_backups/presentation/server_core_backup_file_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(
    'com.ersingundem.larenor/core_backup_destination',
  );

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'Android destination sends only bounded chunks and exact commit proof',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'open' => {'handle': 'a' * 32},
              'append' => null,
              'commit' => 'content://larenor/backups/export',
              _ => throw PlatformException(code: 'missing'),
            };
          });
      final access = ServerCoreBackupFileAccess(
        channel: channel,
        isAndroid: true,
        operationIdFactory: () => 'a' * 32,
      );

      final destination = await access.open('larenor-core-backup.larenor-core');
      expect(destination, isNotNull);
      await destination!.add(Uint8List(64 * 1024));
      expect(
        () => destination.add(Uint8List(64 * 1024 + 1)),
        throwsA(isA<ArgumentError>()),
      );
      final uri = await destination.commit(
        byteLength: 64 * 1024,
        sha256: 'b' * 64,
      );

      expect(uri, Uri.parse('content://larenor/backups/export'));
      expect(calls.map((call) => call.method), ['open', 'append', 'commit']);
      expect((calls[1].arguments as Map)['bytes'], isA<Uint8List>());
      expect(calls[2].arguments, {
        'sessionId': 'a' * 32,
        'handle': 'a' * 32,
        'byteLength': 64 * 1024,
        'sha256': 'b' * 64,
      });
    },
  );

  test('cancelling a pending picker retires its stale callback', () async {
    final calls = <MethodCall>[];
    final opened = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'open') return opened.future;
          return null;
        });
    final access = ServerCoreBackupFileAccess(
      channel: channel,
      isAndroid: true,
      operationIdFactory: () => 'a' * 32,
    );

    final pending = access.open('larenor-core-backup.larenor-core');
    await Future<void>.delayed(Duration.zero);
    await access.cancelPending();
    opened.complete({'handle': 'a' * 32});

    expect(await pending, isNull);
    expect(calls.map((call) => call.method), ['open', 'cancel', 'cancel']);
  });

  test('picker cancellation releases the scoped operation', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    final access = ServerCoreBackupFileAccess(
      channel: channel,
      isAndroid: true,
      operationIdFactory: () => 'a' * 32,
    );

    expect(await access.open('larenor-core-backup.larenor-core'), isNull);
    expect(access.hasPendingOperation, isFalse);
  });

  test('terminal cleanup absorbs a native cancellation timeout', () async {
    final never = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'open') return {'handle': 'b' * 32};
          return never.future;
        });
    final access = ServerCoreBackupFileAccess(
      channel: channel,
      isAndroid: true,
      operationIdFactory: () => 'a' * 32,
      platformTimeout: const Duration(milliseconds: 1),
    );
    await access.open('larenor-core-backup.larenor-core');

    await expectLater(access.cancelPending(), completes);
    expect(access.hasPendingOperation, isFalse);
  });

  test(
    'stale owner cancellation carries only its captured operation',
    () async {
      final calls = <MethodCall>[];
      final oldCancel = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            final session = (call.arguments as Map)['sessionId'];
            if (call.method == 'open') return {'handle': session};
            if (call.method == 'cancel' && session == 'a' * 32) {
              await oldCancel.future;
              return null;
            }
            return null;
          });
      final oldOwner = ServerCoreBackupFileAccess(
        channel: channel,
        isAndroid: true,
        operationIdFactory: () => 'a' * 32,
      );
      final newOwner = ServerCoreBackupFileAccess(
        channel: channel,
        isAndroid: true,
        operationIdFactory: () => 'b' * 32,
      );
      await oldOwner.open('larenor-core-backup.larenor-core');

      final staleCleanup = oldOwner.cancelPending();
      final current = await newOwner.open('larenor-core-backup.larenor-core');
      oldCancel.complete();
      await staleCleanup;

      expect(current, isNotNull);
      expect(
        calls
            .where((call) => call.method == 'cancel')
            .map((call) => (call.arguments as Map)['sessionId']),
        ['a' * 32],
      );
      await current!.add(Uint8List.fromList([1]));
      await current.cancel();
    },
  );

  test(
    'late append completion cannot reopen a cancelled destination',
    () async {
      final append = Completer<void>();
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            if (call.method == 'open') return {'handle': 'b' * 32};
            if (call.method == 'append') await append.future;
            return null;
          });
      final access = ServerCoreBackupFileAccess(
        channel: channel,
        isAndroid: true,
        operationIdFactory: () => 'a' * 32,
      );
      final destination = await access.open('larenor-core-backup.larenor-core');

      final lateAdd = destination!.add(Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(Duration.zero);
      await destination.cancel();
      append.complete();

      await expectLater(lateAdd, throwsStateError);
      await expectLater(
        destination.commit(byteLength: 3, sha256: 'c' * 64),
        throwsArgumentError,
      );
      expect(methods, ['open', 'append', 'cancel']);
    },
  );
}
