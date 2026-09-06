import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/backup/data/backup_codec.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/home_scope/data/core_layout_archive_codec.dart';
import 'package:larenor/features/home_scope/domain/core_layout_archive.dart';

const passphrase = 'Ayrı oda arşivi 🌿 şifresi';
const codec = CoreLayoutArchiveCodec();
const salt = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
const nonce = [16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27];

CoreLayoutArchiveV1 archive() => CoreLayoutArchiveV1.fromJson({
  'kind': 'core-room-layout',
  'version': 1,
  'capturedAt': '2026-09-06T12:00:00.000Z',
  'scopeDigest': 'a' * 64,
  'sourceRevision': 7,
  'rooms': [
    {'id': 'first-room', 'name': 'Çalışma odası 🌿'},
    {'id': 'second-room', 'name': 'Oturma odası'},
  ],
});

Map<String, dynamic> header({String format = 'larenor-core-layout-archive'}) => {
  'format': format,
  'version': 1,
  'kdf': {
    'name': 'PBKDF2-HMAC-SHA256',
    'iterations': 600000,
    'salt': base64Encode(salt),
  },
  'cipher': {'name': 'AES-256-GCM', 'nonce': base64Encode(nonce)},
};

Uint8List bytes(Object? value) => Uint8List.fromList(utf8.encode(jsonEncode(value)));
Map<String, dynamic> envelope(Uint8List value) =>
    jsonDecode(utf8.decode(value)) as Map<String, dynamic>;
Matcher fails(String code) => throwsA(
  isA<CoreLayoutArchiveCodecException>()
      .having((error) => error.code, 'static code', code)
      .having((error) => error.toString(), 'safe error', isNot(contains(passphrase))),
);

// Test-only independent AEAD fixture. There is no key/salt/nonce injection seam
// in the production codec. This can seal deliberately invalid inner documents.
Future<Uint8List> seal(SecretKey key, List<int> plaintext, {Map<String, dynamic>? aad}) async {
  final h = aad ?? header();
  final box = await AesGcm.with256bits().encrypt(
    plaintext, secretKey: key, nonce: nonce, aad: utf8.encode(jsonEncode(h)),
  );
  return bytes({...h, 'ciphertext': base64Encode(box.cipherText), 'tag': base64Encode(box.mac.bytes)});
}

void main() {
  late SecretKey fixtureKey;
  late Uint8List encrypted;
  setUpAll(() async {
    fixtureKey = await Pbkdf2.hmacSha256(iterations: 600000, bits: 256)
        .deriveKeyFromPassword(password: passphrase, nonce: salt);
    encrypted = await seal(fixtureKey, utf8.encode(archive().encode()));
  });
  tearDownAll(() => fixtureKey.destroy());

  test('independent fixed-primitive fixture decrypts only to the exact model', () async {
    final decoded = await codec.decrypt(encrypted, passphrase);
    expect(decoded.toJson(), archive().toJson());
    expect(CoreLayoutArchiveCodec.pbkdf2Iterations, 600000);
    expect(CoreLayoutArchiveCodec.maxFileBytes, 3 * 1024 * 1024);
  });

  test('Unicode portable roundtrip conceals room metadata without device keys', () async {
    final result = await codec.encrypt(archive(), passphrase);
    expect(result.length, lessThanOrEqualTo(CoreLayoutArchiveCodec.maxFileBytes));
    final text = utf8.decode(result);
    for (final hidden in ['Çalışma', 'first-room', 'sourceRevision', 'a' * 64, passphrase]) {
      expect(text, isNot(contains(hidden)));
    }
    final value = envelope(result);
    expect(value['format'], 'larenor-core-layout-archive');
    expect(value['version'], 1);
    expect(base64Decode(value['kdf']['salt'] as String).length, 16);
    expect(base64Decode(value['cipher']['nonce'] as String).length, 12);
    expect(base64Decode(value['tag'] as String).length, 16);
    expect((await codec.decrypt(result, passphrase)).toJson(), archive().toJson());
  });

  test('fresh random salt and nonce and worker isolate preserve caller responsiveness', () async {
    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 10), (_) => ticks++);
    try {
      final first = await codec.encrypt(archive(), passphrase);
      final second = await codec.encrypt(archive(), passphrase);
      final a = envelope(first), b = envelope(second);
      expect(a['kdf']['salt'], isNot(b['kdf']['salt']));
      expect(a['cipher']['nonce'], isNot(b['cipher']['nonce']));
      expect(a['ciphertext'], isNot(b['ciphertext']));
      expect(ticks, greaterThan(1));
    } finally {
      timer.cancel();
    }
  });

  test('input bytes are snapshotted before asynchronous derivation', () async {
    final mutable = Uint8List.fromList(encrypted);
    final future = codec.decrypt(mutable, passphrase);
    mutable.fillRange(0, mutable.length, 0);
    expect((await future).toJson(), archive().toJson());
  });

  test('wrong passphrase and visually similar Unicode are not normalized', () async {
    await expectLater(codec.decrypt(encrypted, 'Different long archive phrase'), fails('decrypt_failed'));
    final composed = 'özel arşiv şifresi é';
    final result = await codec.encrypt(archive(), composed);
    await expectLater(codec.decrypt(result, 'özel arşiv şifresi e\u0301'), fails('decrypt_failed'));
  });

  for (final field in ['salt', 'nonce', 'ciphertext', 'tag']) {
    test('authenticated $field change is rejected', () async {
      final changed = envelope(encrypted);
      final owner = field == 'salt' ? changed['kdf'] as Map : field == 'nonce' ? changed['cipher'] as Map : changed;
      final value = base64Decode(owner[field] as String);
      value[0] ^= 1;
      owner[field] = base64Encode(value);
      await expectLater(codec.decrypt(bytes(changed), passphrase), fails('decrypt_failed'));
    });
  }

  test('the format discriminator is AAD, not just an unauthenticated label', () async {
    final foreign = await seal(fixtureKey, utf8.encode(archive().encode()), aad: header(format: 'larenor-vault'));
    final relabelled = envelope(foreign)..['format'] = 'larenor-core-layout-archive';
    await expectLater(codec.decrypt(bytes(relabelled), passphrase), fails('decrypt_failed'));
  });

  test('legacy vault and Core archive reject each other without format fallback', () async {
    final legacy = BackupSnapshot.fromJson({
      'version': 1, 'createdAt': '2026-09-06T00:00:00.000Z',
      'groups': {'settings': {'appearance': 'dark'}},
    });
    final oldFile = await const BackupCodec().encrypt(legacy, passphrase);
    await expectLater(codec.decrypt(oldFile, passphrase), fails('invalid_archive'));
    await expectLater(
      const BackupCodec().decrypt(encrypted, passphrase), throwsA(isA<BackupException>()),
    );
  });

  final invalidHeader = <String, void Function(Map<String, dynamic>)>{
    'wrong format': (v) => v['format'] = 'larenor-vault',
    'unknown version': (v) => v['version'] = 2,
    'bool version': (v) => v['version'] = true,
    'double version': (v) => v['version'] = 1.0,
    'extra envelope field': (v) => v['secret'] = passphrase,
    'missing envelope field': (v) => v.remove('tag'),
    'wrong kdf': (v) => v['kdf']['name'] = 'scrypt',
    'unbounded cost': (v) => v['kdf']['iterations'] = 9223372036854775807,
    'downgraded cost': (v) => v['kdf']['iterations'] = 1,
    'double cost': (v) => v['kdf']['iterations'] = 600000.0,
    'bool cost': (v) => v['kdf']['iterations'] = true,
    'string cost': (v) => v['kdf']['iterations'] = '600000',
    'extra kdf key': (v) => v['kdf']['memory'] = 1000000000,
    'missing kdf key': (v) => v['kdf'].remove('salt'),
    'nonobject kdf': (v) => v['kdf'] = [],
    'wrong cipher': (v) => v['cipher']['name'] = 'AES-128-GCM',
    'extra cipher field': (v) => v['cipher']['key'] = passphrase,
    'nonobject cipher': (v) => v['cipher'] = null,
    'short salt': (v) => v['kdf']['salt'] = base64Encode([1]),
    'long salt': (v) => v['kdf']['salt'] = base64Encode(List.filled(17, 1)),
    'short nonce': (v) => v['cipher']['nonce'] = base64Encode([1]),
    'long nonce': (v) => v['cipher']['nonce'] = base64Encode(List.filled(13, 1)),
    'short tag': (v) => v['tag'] = base64Encode([1]),
    'long tag': (v) => v['tag'] = base64Encode(List.filled(17, 1)),
    'untyped salt': (v) => v['kdf']['salt'] = 1,
    'invalid base64': (v) => v['tag'] = '***',
    'unpadded salt': (v) => v['kdf']['salt'] = (v['kdf']['salt'] as String).replaceAll('=', ''),
    'base64url nonce': (v) => v['cipher']['nonce'] = base64Encode(List.filled(12, 255)).replaceAll('/', '_'),
    'percent escaped salt': (v) => v['kdf']['salt'] = (v['kdf']['salt'] as String).replaceAll('=', '%3D'),
    'noncanonical pad bits': (v) => v['tag'] = 'AAAAAAAAAAAAAAAAAAAAAB==',
    'empty ciphertext': (v) => v['ciphertext'] = '',
    'oversized ciphertext': (v) => v['ciphertext'] = base64Encode(Uint8List(maxCoreLayoutArchiveBytes + 1)),
  };
  for (final change in invalidHeader.entries) {
    test('closed pre-KDF header rejects ${change.key}', () async {
      final value = envelope(encrypted);
      change.value(value);
      await expectLater(codec.decrypt(bytes(value), passphrase), fails('invalid_archive'));
    });
  }

  test('JSON key order and whitespace do not alter canonical authenticated header', () async {
    final value = envelope(encrypted);
    final reordered = {for (final entry in value.entries.toList().reversed) entry.key: entry.value};
    reordered['kdf'] = {
      'salt': value['kdf']['salt'], 'iterations': 600000, 'name': 'PBKDF2-HMAC-SHA256',
    };
    final input = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(reordered)));
    expect((await codec.decrypt(input, passphrase)).toJson(), archive().toJson());
  });

  test('exact 3MiB file is accepted and one extra byte is rejected', () async {
    final input = Uint8List(CoreLayoutArchiveCodec.maxFileBytes)..fillRange(0, CoreLayoutArchiveCodec.maxFileBytes, 32);
    input.setRange(0, encrypted.length, encrypted);
    expect((await codec.decrypt(input, passphrase)).toJson(), archive().toJson());
    await expectLater(codec.decrypt(Uint8List(CoreLayoutArchiveCodec.maxFileBytes + 1), passphrase), fails('archive_too_large'));
  });

  test('authenticated 2MiB plaintext boundary returns the model without hidden truncation', () async {
    final raw = utf8.encode(archive().encode());
    final padded = Uint8List(maxCoreLayoutArchiveBytes)..fillRange(0, maxCoreLayoutArchiveBytes, 32);
    padded.setRange(0, raw.length, raw);
    final result = await seal(fixtureKey, padded);
    expect(result.length, lessThanOrEqualTo(CoreLayoutArchiveCodec.maxFileBytes));
    expect((await codec.decrypt(result, passphrase)).toJson(), archive().toJson());
  });

  final badInner = <String, Object?>{
    'wrong kind': {...archive().toJson(), 'kind': 'larenor-vault'},
    'unknown version': {...archive().toJson(), 'version': 2},
    'unknown field': {...archive().toJson(), 'token': 'private-token'},
    'wrong shape': [],
    'missing rooms': {...archive().toJson()}..remove('rooms'),
  };
  for (final entry in badInner.entries) {
    test('authenticated plaintext still rejects ${entry.key}', () async {
      final input = await seal(fixtureKey, utf8.encode(jsonEncode(entry.value)));
      await expectLater(codec.decrypt(input, passphrase), fails('invalid_archive'));
    });
  }
  test('authenticated non-UTF8 plaintext is rejected', () async {
    final input = await seal(fixtureKey, [0xff, 0xfe]);
    await expectLater(codec.decrypt(input, passphrase), fails('invalid_archive'));
  });

  test('invalid, non-UTF8, truncated and nonobject files fail statically', () async {
    for (final value in [
      Uint8List(0), Uint8List.fromList([0xff]), bytes([]), bytes(null),
      Uint8List.fromList(utf8.encode('secret $passphrase')),
      encrypted.sublist(0, encrypted.length - 1),
    ]) {
      await expectLater(codec.decrypt(value, passphrase), fails('invalid_archive'));
    }
  });

  test('passphrase policy preserves exact Unicode and enforces rune/UTF8 limits', () {
    for (final value in ['', 'short', '🌿' * 11, 'x' * 1025, '🌿' * 257, 'long-enough-\ud800']) {
      expect(() => CoreLayoutArchiveCodec.validatePassphrase(value), fails('invalid_passphrase'));
    }
    for (final value in ['🌿' * 12, 'x' * 1024, '🌿' * 256, passphrase]) {
      CoreLayoutArchiveCodec.validatePassphrase(value, settingsPin: '123456');
    }
    expect(
      () => CoreLayoutArchiveCodec.validatePassphrase('123456789012', settingsPin: '123456789012'),
      fails('invalid_passphrase'),
    );
  });

  test('public operations both validate passphrase without any fallback', () async {
    await expectLater(codec.encrypt(archive(), 'short'), fails('invalid_passphrase'));
    await expectLater(codec.decrypt(encrypted, 'short'), fails('invalid_passphrase'));
  });
}
