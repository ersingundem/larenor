import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/backup/data/backup_codec.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';

import 'backup_test_storage.dart';

void main() {
  const codec = BackupCodec();
  const passphrase = 'a separate fixture vault passphrase';
  final snapshot = BackupSnapshot.fromJson({
    'version': 1,
    'createdAt': '2026-09-05T00:00:00.000Z',
    'groups': {
      'settings': {'appearance': 'dark'},
      'connections': {
        'ha': {
          'baseUrl': 'http://192.0.2.1:8123',
          'token': 'fixture-private-ha-token',
        },
      },
    },
  });
  late Uint8List encrypted;

  setUpAll(() async {
    encrypted = await codec.encrypt(snapshot, passphrase);
  });

  test(
    'portable roundtrip imports into empty storage without any old device key',
    () async {
      final fileText = utf8.decode(encrypted);
      expect(fileText, isNot(contains('fixture-private-ha-token')));
      expect(fileText, isNot(contains('192.0.2.1')));
      expect(fileText, isNot(contains('appearance')));
      final decrypted = await codec.decrypt(encrypted, passphrase);
      expect(decrypted.toJson(), snapshot.toJson());
      final target = MemoryBackupStorage();
      await BackupRepository(storage: target)
          .restore(decrypted, const BackupSelection(connections: true));
      expect(target.secrets['ha_token'], 'fixture-private-ha-token');
      expect(target.preferences['appearance'], 'dark');
    },
  );

  test('encryption uses fresh salt and nonce and leaves the caller isolate responsive', () async {
    var ticks = 0;
    final ticker = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => ticks++,
    );
    final second = await codec.encrypt(snapshot, passphrase);
    ticker.cancel();
    final firstJson = jsonDecode(utf8.decode(encrypted)) as Map;
    final secondJson = jsonDecode(utf8.decode(second)) as Map;
    expect(
      (firstJson['kdf'] as Map)['salt'],
      isNot((secondJson['kdf'] as Map)['salt']),
    );
    expect(
      (firstJson['cipher'] as Map)['nonce'],
      isNot((secondJson['cipher'] as Map)['nonce']),
    );
    expect(second, isNot(encrypted));
    expect(ticks, greaterThan(1));
  });

  test('wrong passphrase performs no restore writes and does not reveal secret values', () async {
    final target = MemoryBackupStorage();
    await expectLater(
      () async {
        final result = await codec.decrypt(
          encrypted,
          'another incorrect vault passphrase',
        );
        await BackupRepository(storage: target)
            .restore(result, const BackupSelection(connections: true));
      }(),
      throwsA(
        isA<BackupException>()
            .having((e) => e.code, 'code', 'decrypt_failed')
            .having(
              (e) => e.toString(),
              'safe error',
              isNot(contains('fixture-private')),
            ),
      ),
    );
    expect(target.writes, isEmpty);
  });

  test('changed authentication tag performs no restore writes', () async {
    final envelope = jsonDecode(utf8.decode(encrypted)) as Map<String, dynamic>;
    final tag = base64Decode(envelope['tag'] as String);
    tag[0] ^= 1;
    envelope['tag'] = base64Encode(tag);
    final target = MemoryBackupStorage();
    await expectLater(
      () async {
        final result = await codec.decrypt(
          Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
          passphrase,
        );
        await BackupRepository(storage: target)
            .restore(result, const BackupSelection(connections: true));
      }(),
      throwsA(
        isA<BackupException>().having((e) => e.code, 'code', 'decrypt_failed'),
      ),
    );
    expect(target.writes, isEmpty);
  });

  for (final mutation in <String, void Function(Map<String, dynamic>)>{
    'unsupported version': (e) => e['version'] = 2,
    'non-integer version': (e) => e['version'] = 1.0,
    'unknown cipher': (e) => (e['cipher'] as Map)['name'] = 'AES-ECB',
    'unbounded KDF': (e) => (e['kdf'] as Map)['iterations'] = 999999999999,
    'downgraded KDF': (e) => (e['kdf'] as Map)['iterations'] = 1,
    'non-integer KDF': (e) => (e['kdf'] as Map)['iterations'] = 600000.0,
    'wrong nonce size': (e) =>
        (e['cipher'] as Map)['nonce'] = base64Encode([1]),
    'wrong salt size': (e) => (e['kdf'] as Map)['salt'] = base64Encode([1]),
    'unknown envelope key': (e) => e['debug'] = 'fixture-private-ha-token',
  }.entries) {
    test(
      '${mutation.key} is rejected before expensive key derivation',
      () async {
        final envelope =
            jsonDecode(utf8.decode(encrypted)) as Map<String, dynamic>;
        mutation.value(envelope);
        await expectLater(
          codec.decrypt(
            Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
            passphrase,
          ),
          throwsA(isA<BackupException>()),
        );
      },
    );
  }

  test('invalid and oversized files fail safely', () async {
    await expectLater(
      codec.decrypt(
        Uint8List.fromList(utf8.encode('not a vault: fixture-secret')),
        passphrase,
      ),
      throwsA(
        isA<BackupException>().having(
          (e) => e.toString(),
          'safe error',
          isNot(contains('fixture-secret')),
        ),
      ),
    );
    await expectLater(
      codec.decrypt(Uint8List(BackupCodec.maxFileBytes + 1), passphrase),
      throwsA(
        isA<BackupException>().having((e) => e.code, 'code', 'too_large'),
      ),
    );
  });

  test('export passphrase must be separate from Settings PIN and at least twelve characters', () {
    expect(
      () => BackupCodec.validatePassphrase('short'),
      throwsA(isA<BackupException>()),
    );
    expect(
      () => BackupCodec.validatePassphrase(
        '123456789012',
        settingsPin: '123456789012',
      ),
      throwsA(isA<BackupException>()),
    );
    expect(
      () => BackupCodec.validatePassphrase('a' * 1025),
      throwsA(isA<BackupException>()),
    );
    BackupCodec.validatePassphrase(passphrase, settingsPin: '123456');
  });
}
