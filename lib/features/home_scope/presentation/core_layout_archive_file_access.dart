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
  });
  static const maxFileBytes = CoreLayoutArchiveCodec.maxFileBytes;
  Future<Uint8List?> pick() async => throw const CoreLayoutArchiveFileException();
  Future<Uri?> save(Uint8List bytes) async => throw const CoreLayoutArchiveFileException();
}

class CoreLayoutArchiveFileException implements Exception {
  const CoreLayoutArchiveFileException();
}
