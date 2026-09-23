import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/core_backups/presentation/server_core_backup_source_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(ServerCoreBackupSourceAccess.channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'opens only the exact backup MIME and returns secret-free proof',
    () async {
      MethodCall? captured;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            captured = call;
            return {'byteLength': 65, 'sha256': 'a' * 64};
          });
      final access = ServerCoreBackupSourceAccess(
        channel: channel,
        isAndroid: true,
        operationIdFactory: () => '1' * 32,
      );

      final proof = await access.inspect();

      expect(captured?.method, 'inspect');
      expect(captured?.arguments, {
        'sessionId': '1' * 32,
        'mimeType': 'application/vnd.larenor.core-backup',
      });
      expect(proof?.byteLength, 65);
      expect(proof?.sha256, 'a' * 64);
      expect(access.hasPendingOperation, isFalse);
    },
  );

  test('rejects malformed or oversized native proof', () async {
    final replies = <Object?>[
      {'byteLength': 65, 'sha256': 'a' * 64, 'uri': 'content://secret'},
      {
        'byteLength': ServerCoreBackupSourceAccess.maxBytes + 1,
        'sha256': 'a' * 64,
      },
      {'byteLength': 65, 'sha256': 'A' * 64},
    ].iterator;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'cancel') return null;
          replies.moveNext();
          return replies.current;
        });
    var sequence = 0;
    final access = ServerCoreBackupSourceAccess(
      channel: channel,
      isAndroid: true,
      operationIdFactory: () => (++sequence).toRadixString(16).padLeft(32, '0'),
    );

    await expectLater(access.inspect(), throwsFormatException);
    await expectLater(access.inspect(), throwsFormatException);
    await expectLater(access.inspect(), throwsFormatException);
  });

  test(
    'picker cancellation and unsupported platforms do not expose a source',
    () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            calls++;
            return null;
          });
      final android = ServerCoreBackupSourceAccess(
        channel: channel,
        isAndroid: true,
        operationIdFactory: () => '2' * 32,
      );
      final other = ServerCoreBackupSourceAccess(
        channel: channel,
        isAndroid: false,
      );

      expect(await android.inspect(), isNull);
      expect(await other.inspect(), isNull);
      expect(calls, 1);
    },
  );

  test(
    'captured lifecycle cancellation cannot cancel the next owner',
    () async {
      final calls = <MethodCall>[];
      final firstOpen = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            final session = (call.arguments as Map)['sessionId'];
            if (call.method == 'inspect' && session == 'a' * 32) {
              return firstOpen.future;
            }
            if (call.method == 'inspect') {
              return {'byteLength': 65, 'sha256': 'b' * 64};
            }
            return null;
          });
      final oldOwner = ServerCoreBackupSourceAccess(
        channel: channel,
        isAndroid: true,
        operationIdFactory: () => 'a' * 32,
      );
      final newOwner = ServerCoreBackupSourceAccess(
        channel: channel,
        isAndroid: true,
        operationIdFactory: () => 'b' * 32,
      );

      final stale = oldOwner.inspect();
      await Future<void>.delayed(Duration.zero);
      await oldOwner.cancelPending();
      final current = await newOwner.inspect();
      firstOpen.complete(null);

      expect(await stale, isNull);
      expect(current?.sha256, 'b' * 64);
      expect(
        calls
            .where((call) => call.method == 'cancel')
            .map((call) => (call.arguments as Map)['sessionId']),
        ['a' * 32],
      );
    },
  );

  test('cleanup suppresses platform timeout during teardown', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'inspect') {
            await Completer<void>().future;
          } else {
            await Completer<void>().future;
          }
          return null;
        });
    final access = ServerCoreBackupSourceAccess(
      channel: channel,
      isAndroid: true,
      operationIdFactory: () => 'c' * 32,
      platformTimeout: Duration.zero,
    );

    unawaited(access.inspect());
    await Future<void>.delayed(Duration.zero);
    await expectLater(access.cancelPending(), completes);
  });
}
