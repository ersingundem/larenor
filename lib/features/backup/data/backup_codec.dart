import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'backup_snapshot.dart';

/// Portable encryption; the vault key is never tied to the old installation's
/// Keystore. KDF work runs in a worker isolate, not the Flutter UI isolate.
class BackupCodec {
  const BackupCodec();
  static const maxFileBytes = 3 * 1024 * 1024;
  static const pbkdf2Iterations = 600000;

  static void validatePassphrase(String passphrase, {String? settingsPin}) {
    if (passphrase.runes.length < 12 ||
        utf8.encode(passphrase).length > 1024 ||
        (settingsPin != null && passphrase == settingsPin)) {
      throw const BackupException(
        'invalid_passphrase',
        'Use a separate backup passphrase with at least 12 characters.',
      );
    }
  }

  Future<Uint8List> encrypt(BackupSnapshot snapshot, String passphrase) async {
    validatePassphrase(passphrase);
    final json = snapshot.toJson();
    validateBackupJson(json);
    return Isolate.run(() => _encrypt(json, passphrase));
  }

  Future<BackupSnapshot> decrypt(Uint8List bytes, String passphrase) async {
    validatePassphrase(passphrase);
    if (bytes.length > maxFileBytes) {
      throw const BackupException('too_large', 'The backup file is too large.');
    }
    // Bound work before starting PBKDF2. Imported parameters never control
    // iterations, memory allocation or algorithm selection.
    final envelope = _readEnvelope(bytes);
    final json = await Isolate.run(() => _decrypt(envelope, passphrase));
    return BackupSnapshot.fromJson(json);
  }
}

Map<String, dynamic> _header(List<int> salt, List<int> nonce) => {
  'format': 'larenor-vault',
  'version': 1,
  'kdf': {
    'name': 'PBKDF2-HMAC-SHA256',
    'iterations': BackupCodec.pbkdf2Iterations,
    'salt': base64Encode(salt),
  },
  'cipher': {'name': 'AES-256-GCM', 'nonce': base64Encode(nonce)},
};

Future<SecretKey> _derive(String passphrase, List<int> salt) =>
    Pbkdf2.hmacSha256(
      iterations: BackupCodec.pbkdf2Iterations,
      bits: 256,
    ).deriveKeyFromPassword(password: passphrase, nonce: salt);

Future<Uint8List> _encrypt(Map<String, dynamic> json, String passphrase) async {
  final random = Random.secure();
  final salt = List<int>.generate(16, (_) => random.nextInt(256));
  final cipher = AesGcm.with256bits();
  final nonce = cipher.newNonce();
  final header = _header(salt, nonce);
  final key = await _derive(passphrase, salt);
  final plain = Uint8List.fromList(utf8.encode(jsonEncode(json)));
  try {
    final box = await cipher.encrypt(
      plain,
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode(jsonEncode(header)),
    );
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          ...header,
          'ciphertext': base64Encode(box.cipherText),
          'tag': base64Encode(box.mac.bytes),
        }),
      ),
    );
  } finally {
    key.destroy();
    plain.fillRange(0, plain.length, 0);
  }
}

Map<String, dynamic> _readEnvelope(Uint8List bytes) {
  try {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, dynamic> ||
        !_keys(json, {
          'format',
          'version',
          'kdf',
          'cipher',
          'ciphertext',
          'tag',
        }) ||
        json['format'] != 'larenor-vault' ||
        json['version'] is! int ||
        json['version'] != 1) {
      throw const BackupValidationException();
    }
    final kdf = json['kdf'];
    final cipher = json['cipher'];
    if (kdf is! Map<String, dynamic> ||
        !_keys(kdf, {'name', 'iterations', 'salt'}) ||
        kdf['name'] != 'PBKDF2-HMAC-SHA256' ||
        kdf['iterations'] is! int ||
        kdf['iterations'] != BackupCodec.pbkdf2Iterations ||
        cipher is! Map<String, dynamic> ||
        !_keys(cipher, {'name', 'nonce'}) ||
        cipher['name'] != 'AES-256-GCM') {
      throw const BackupValidationException();
    }
    _decode(kdf['salt'], exactLength: 16);
    _decode(cipher['nonce'], exactLength: 12);
    _decode(json['tag'], exactLength: 16);
    final ciphertext = _decode(json['ciphertext']);
    if (ciphertext.isEmpty || ciphertext.length > maxBackupPlaintextBytes) {
      throw const BackupValidationException();
    }
    return json;
  } on BackupException {
    rethrow;
  } catch (_) {
    throw const BackupValidationException(
      'The file is not a supported Larenor vault.',
    );
  }
}

bool _keys(Map<String, dynamic> value, Set<String> keys) =>
    value.length == keys.length && keys.containsAll(value.keys);

Uint8List _decode(Object? value, {int? exactLength}) {
  if (value is! String) throw const BackupValidationException();
  final bytes = base64Decode(value);
  if (exactLength != null && bytes.length != exactLength) {
    throw const BackupValidationException();
  }
  return bytes;
}

Future<Map<String, dynamic>> _decrypt(
  Map<String, dynamic> envelope,
  String passphrase,
) async {
  final salt = _decode((envelope['kdf'] as Map)['salt']);
  final nonce = _decode((envelope['cipher'] as Map)['nonce']);
  final key = await _derive(passphrase, salt);
  List<int>? plaintext;
  try {
    plaintext = await AesGcm.with256bits().decrypt(
      SecretBox(
        _decode(envelope['ciphertext']),
        nonce: nonce,
        mac: Mac(_decode(envelope['tag'])),
      ),
      secretKey: key,
      aad: utf8.encode(jsonEncode(_header(salt, nonce))),
    );
    final json = jsonDecode(utf8.decode(plaintext));
    validateBackupJson(json);
    return json as Map<String, dynamic>;
  } on SecretBoxAuthenticationError {
    throw const BackupException(
      'decrypt_failed',
      'The passphrase is incorrect or the backup file has been modified.',
    );
  } on BackupException {
    rethrow;
  } catch (_) {
    throw const BackupValidationException();
  } finally {
    key.destroy();
    plaintext?.fillRange(0, plaintext.length, 0);
  }
}
