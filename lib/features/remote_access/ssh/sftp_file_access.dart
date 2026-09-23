import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'sftp_models.dart';

typedef SftpPickFile = Future<SftpUpload?> Function();
typedef SftpSaveFile = Future<Uri?> Function(String name, Uint8List bytes);

class SftpFileAccess {
  SftpFileAccess({SftpPickFile? pickFile, SftpSaveFile? saveFile})
    : _pickFile = pickFile ?? _pick,
      _saveFile = saveFile ?? _save;

  final SftpPickFile _pickFile;
  final SftpSaveFile _saveFile;

  static Future<SftpUpload?> _pick() async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null) return null;
    final declaredLength = await file.length();
    if (declaredLength == null) {
      throw const SftpFailure('file_access_failed');
    }
    return collectUpload(
      name: file.name,
      declaredLength: declaredLength,
      chunks: file.readAsByteStream(),
    );
  }

  static Future<Uri?> _save(String name, Uint8List bytes) =>
      FilePicker.saveFile(fileName: name, bytes: bytes);

  Future<SftpUpload?> pickUpload() async {
    try {
      return await _pickFile();
    } on SftpFailure {
      rethrow;
    } catch (_) {
      throw const SftpFailure('file_access_failed');
    }
  }

  Future<bool> saveDownload(String name, Uint8List bytes) async {
    joinSftpPath('/', name);
    if (bytes.length > sftpMaxTransferBytes) {
      throw const SftpFailure('file_too_large');
    }
    final exported = Uint8List.fromList(bytes);
    try {
      return await _saveFile(name, exported) != null;
    } catch (_) {
      throw const SftpFailure('file_access_failed');
    } finally {
      exported.fillRange(0, exported.length, 0);
    }
  }

  static Future<SftpUpload> collectUpload({
    required String name,
    required int declaredLength,
    required Stream<Uint8List> chunks,
  }) async {
    joinSftpPath('/', name);
    if (declaredLength < 0 || declaredLength > sftpMaxTransferBytes) {
      throw const SftpFailure('file_too_large');
    }
    final owned = Uint8List(declaredLength);
    var offset = 0;
    try {
      await for (final chunk in chunks) {
        if (chunk.length > declaredLength - offset) {
          throw const SftpFailure('file_too_large');
        }
        owned.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      if (offset != declaredLength) {
        throw const SftpFailure('file_changed');
      }
      return SftpUpload.adoptOwned(name, owned);
    } catch (error) {
      owned.fillRange(0, owned.length, 0);
      if (error is SftpFailure) rethrow;
      throw const SftpFailure('file_access_failed');
    }
  }
}
