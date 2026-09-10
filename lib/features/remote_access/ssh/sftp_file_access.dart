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
    return collectUpload(
      name: file.name,
      declaredLength: await file.length(),
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
    try {
      return await _saveFile(name, Uint8List.fromList(bytes)) != null;
    } catch (_) {
      throw const SftpFailure('file_access_failed');
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
    final builder = BytesBuilder(copy: false);
    await for (final chunk in chunks) {
      if (builder.length + chunk.length > sftpMaxTransferBytes ||
          builder.length + chunk.length > declaredLength) {
        throw const SftpFailure('file_too_large');
      }
      builder.add(chunk);
    }
    if (builder.length != declaredLength) {
      throw const SftpFailure('file_changed');
    }
    return SftpUpload(name, builder.takeBytes());
  }
}
