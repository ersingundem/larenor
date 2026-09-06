import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/core_layout_archive_codec.dart';

final coreLayoutArchiveFileAccessProvider = Provider<CoreLayoutArchiveFileAccess>(
  (_) => CoreLayoutArchiveFileAccess(),
);

class CoreLayoutArchiveFileAccess {
  CoreLayoutArchiveFileAccess({
    Future<PlatformFile?> Function()? pickFile,
    Future<Uri?> Function(Uint8List, String)? saveFile,
  }) : _pickFile = pickFile ?? (() => FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['larenor-core-layout'])),
       _saveFile = saveFile ?? ((bytes, name) => FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: 'application/octet-stream'));
  final Future<PlatformFile?> Function() _pickFile;
  final Future<Uri?> Function(Uint8List, String) _saveFile;
  static const maxFileBytes = CoreLayoutArchiveCodec.maxFileBytes;
  Future<Uint8List?> pick() async {
    try {
      final file = await _pickFile();
      if (file == null) return null;
      if (file.extension != 'larenor-core-layout') throw const CoreLayoutArchiveFileException();
      final length = await file.length();
      if (length <= 0 || length > maxFileBytes) throw const CoreLayoutArchiveFileException();
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        if (bytes.length + chunk.length > maxFileBytes) throw const CoreLayoutArchiveFileException();
        bytes.add(chunk);
      }
      if (bytes.length != length) throw const CoreLayoutArchiveFileException();
      return bytes.takeBytes();
    } catch (_) {
      throw const CoreLayoutArchiveFileException();
    }
  }
  // Only ciphertext supplied by the codec is dispatched to the OS. No paths,
  // temporary plaintext files, secret storage or network destinations are used.
  Future<Uri?> save(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxFileBytes) throw const CoreLayoutArchiveFileException();
    final frozen = Uint8List.fromList(bytes);
    try {
      return await _saveFile(frozen, 'larenor-rooms.larenor-core-layout');
    } catch (_) {
      throw const CoreLayoutArchiveFileException();
    }
  }
}

class CoreLayoutArchiveFileException implements Exception {
  const CoreLayoutArchiveFileException();
}
