import 'dart:typed_data';

import '../domain/core_layout_archive.dart';

final class CoreLayoutArchiveCodecException implements Exception {
  const CoreLayoutArchiveCodecException(this.code);
  final String code;
  @override
  String toString() => 'CoreLayoutArchiveCodecException($code)';
}

final class CoreLayoutArchiveCodec {
  const CoreLayoutArchiveCodec();
  static const maxFileBytes = 3 * 1024 * 1024;
  static const pbkdf2Iterations = 600000;
  static void validatePassphrase(String passphrase, {String? settingsPin}) =>
      throw const CoreLayoutArchiveCodecException('invalid_passphrase');
  Future<Uint8List> encrypt(CoreLayoutArchiveV1 archive, String passphrase) async =>
      throw const CoreLayoutArchiveCodecException('invalid_archive');
  Future<CoreLayoutArchiveV1> decrypt(Uint8List bytes, String passphrase) async =>
      throw const CoreLayoutArchiveCodecException('invalid_archive');
}
