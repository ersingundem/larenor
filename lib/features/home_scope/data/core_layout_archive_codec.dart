import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../domain/core_layout_archive.dart';

const _invalid = CoreLayoutArchiveCodecException('invalid_archive');
const _tooLarge = CoreLayoutArchiveCodecException('archive_too_large');

/// Static errors only; never includes plaintext, passphrases or file contents.
final class CoreLayoutArchiveCodecException implements Exception {
  const CoreLayoutArchiveCodecException(this.code);
  final String code;
  @override
  String toString() => 'CoreLayoutArchiveCodecException($code)';
}

/// Separate portable encryption for the closed Core room archive model.
///
/// KDF/AEAD work runs in a worker isolate. This codec performs no file IO,
/// storage, source/session checks or restore, and decoding grants no authority.
final class CoreLayoutArchiveCodec {
  const CoreLayoutArchiveCodec();
  static const maxFileBytes = 3 * 1024 * 1024;
  static const pbkdf2Iterations = 600000;
  static void validatePassphrase(String passphrase, {String? settingsPin}) {
    final runes = passphrase.runes;
    if (runes.length < 12 ||
        utf8.encode(passphrase).length > 1024 ||
        runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff) ||
        settingsPin != null && passphrase == settingsPin) {
      throw const CoreLayoutArchiveCodecException('invalid_passphrase');
    }
  }

  Future<Uint8List> encrypt(CoreLayoutArchiveV1 archive, String passphrase) async {
    validatePassphrase(passphrase);
    try {
      return await Isolate.run(() => _encrypt(archive, passphrase));
    } on CoreLayoutArchiveCodecException {
      rethrow;
    } catch (_) {
      throw const CoreLayoutArchiveCodecException('encrypt_failed');
    }
  }

  Future<CoreLayoutArchiveV1> decrypt(Uint8List bytes, String passphrase) async {
    validatePassphrase(passphrase);
    if (bytes.length > maxFileBytes) throw _tooLarge;
    // Parse/copy and validate all imported algorithm/cost/length fields before
    // starting the KDF. Caller byte mutations cannot alter the accepted input.
    final envelope = _readEnvelope(bytes);
    try {
      return await Isolate.run(() => _decrypt(envelope, passphrase));
    } on CoreLayoutArchiveCodecException {
      rethrow;
    } catch (_) {
      throw _invalid;
    }
  }
}

Map<String, dynamic> _header(List<int> salt, List<int> nonce) => {
  'format': 'larenor-core-layout-archive',
  'version': 1,
  'kdf': {
    'name': 'PBKDF2-HMAC-SHA256',
    'iterations': CoreLayoutArchiveCodec.pbkdf2Iterations,
    'salt': base64Encode(salt),
  },
  'cipher': {'name': 'AES-256-GCM', 'nonce': base64Encode(nonce)},
};

Future<SecretKey> _derive(String passphrase, List<int> salt) =>
    Pbkdf2.hmacSha256(
      iterations: CoreLayoutArchiveCodec.pbkdf2Iterations,
      bits: 256,
    ).deriveKeyFromPassword(password: passphrase, nonce: salt);

Future<Uint8List> _encrypt(CoreLayoutArchiveV1 archive, String passphrase) async {
  final random = Random.secure();
  final salt = List<int>.generate(16, (_) => random.nextInt(256));
  final cipher = AesGcm.with256bits();
  final nonce = cipher.newNonce();
  final header = _header(salt, nonce);
  final plain = Uint8List.fromList(utf8.encode(archive.encode()));
  SecretKey? key;
  try {
    if (plain.isEmpty || plain.length > maxCoreLayoutArchiveBytes) throw _tooLarge;
    key = await _derive(passphrase, salt);
    final box = await cipher.encrypt(
      plain,
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode(jsonEncode(header)),
    );
    final result = Uint8List.fromList(utf8.encode(jsonEncode({
      ...header,
      'ciphertext': base64Encode(box.cipherText),
      'tag': base64Encode(box.mac.bytes),
    })));
    if (result.length > CoreLayoutArchiveCodec.maxFileBytes) throw _tooLarge;
    return result;
  } finally {
    key?.destroy();
    plain.fillRange(0, plain.length, 0);
  }
}

// Private, copied byte fields. It never escapes the codec or accepts caller
// keys/options, and its fixed sizes were checked before KDF dispatch.
final class _Envelope {
  const _Envelope(this.salt, this.nonce, this.ciphertext, this.tag);
  final Uint8List salt, nonce, ciphertext, tag;
}

_Envelope _readEnvelope(Uint8List bytes) {
  try {
    final json = _object(jsonDecode(utf8.decode(bytes)), const {
      'format', 'version', 'kdf', 'cipher', 'ciphertext', 'tag',
    });
    if (json['format'] != 'larenor-core-layout-archive' ||
        json['version'] is! int || json['version'] != 1) {
      throw _invalid;
    }
    final kdf = _object(json['kdf'], const {'name', 'iterations', 'salt'});
    final cipher = _object(json['cipher'], const {'name', 'nonce'});
    if (kdf['name'] != 'PBKDF2-HMAC-SHA256' ||
        kdf['iterations'] is! int ||
        kdf['iterations'] != CoreLayoutArchiveCodec.pbkdf2Iterations ||
        cipher['name'] != 'AES-256-GCM') {
      throw _invalid;
    }
    return _Envelope(
      _base64(kdf['salt'], exactLength: 16),
      _base64(cipher['nonce'], exactLength: 12),
      _base64(json['ciphertext'], maximumLength: maxCoreLayoutArchiveBytes),
      _base64(json['tag'], exactLength: 16),
    );
  } on CoreLayoutArchiveCodecException {
    rethrow;
  } catch (_) {
    throw _invalid;
  }
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> || value.length != keys.length ||
      !keys.containsAll(value.keys)) {
    throw _invalid;
  }
  return value;
}

Uint8List _base64(Object? value, {int? exactLength, int? maximumLength}) {
  if (value is! String) throw _invalid;
  final bytes = base64Decode(value);
  if (bytes.isEmpty ||
      exactLength != null && bytes.length != exactLength ||
      maximumLength != null && bytes.length > maximumLength ||
      base64Encode(bytes) != value) {
    throw _invalid;
  }
  return bytes;
}

Future<CoreLayoutArchiveV1> _decrypt(_Envelope envelope, String passphrase) async {
  SecretKey? key;
  List<int>? plain;
  try {
    key = await _derive(passphrase, envelope.salt);
    plain = await AesGcm.with256bits().decrypt(
      SecretBox(
        envelope.ciphertext,
        nonce: envelope.nonce,
        mac: Mac(envelope.tag),
      ),
      secretKey: key,
      aad: utf8.encode(jsonEncode(_header(envelope.salt, envelope.nonce))),
    );
    if (plain.isEmpty || plain.length > maxCoreLayoutArchiveBytes) throw _tooLarge;
    return CoreLayoutArchiveV1.decode(utf8.decode(plain));
  } on SecretBoxAuthenticationError {
    throw const CoreLayoutArchiveCodecException('decrypt_failed');
  } on CoreLayoutArchiveCodecException {
    rethrow;
  } catch (_) {
    throw _invalid;
  } finally {
    key?.destroy();
    plain?.fillRange(0, plain.length, 0);
  }
}
