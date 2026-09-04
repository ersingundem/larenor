import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../data/backup_codec.dart';

/// The OS owns the destination; plaintext never enters a temporary export file.
class BackupFileAccess {
  static const maxFileBytes = BackupCodec.maxFileBytes;

  Future<Uint8List?> pick() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['larenor-vault'],
    );
    if (file == null) return null;
    if (await file.length() > maxFileBytes) throw const BackupFileTooLarge();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > maxFileBytes) {
        throw const BackupFileTooLarge();
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<Uri?> save(Uint8List bytes, String filename) => FilePicker.saveFile(
    fileName: filename,
    bytes: bytes,
    mimeType: 'application/octet-stream',
  );
}

class BackupFileTooLarge implements Exception {
  const BackupFileTooLarge();
}
