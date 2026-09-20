import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_bounded_download_api.dart';

final class CoreBoundedPickedFile {
  const CoreBoundedPickedFile({
    required this.name,
    required this.declaredLength,
    required this.chunks,
  });
  final String name;
  final int declaredLength;
  final Stream<Uint8List> chunks;
}

typedef CoreBoundedFilePicker = Future<CoreBoundedPickedFile?> Function();

final coreBoundedUploadFileAccessProvider =
    Provider<CoreBoundedUploadFileAccess>((_) => CoreBoundedUploadFileAccess());

/// Reads a picker handle directly into one bounded in-memory value. A platform
/// path is never requested, retained, or sent to Core.
final class CoreBoundedUploadFileAccess {
  CoreBoundedUploadFileAccess({CoreBoundedFilePicker? pick})
    : _pick = pick ?? _platformPick;

  final CoreBoundedFilePicker _pick;

  static Future<CoreBoundedPickedFile?> _platformPick() async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null) return null;
    final declaredLength = await file.length();
    if (declaredLength == null) {
      throw const CoreBoundedDownloadException('file_access_failed');
    }
    return CoreBoundedPickedFile(
      name: file.name,
      declaredLength: declaredLength,
      chunks: file.readAsByteStream(),
    );
  }

  static const _types = <String, String>{
    'pdf': 'application/pdf',
    'txt': 'text/plain; charset=utf-8',
    'json': 'application/json',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
    'gif': 'image/gif',
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'mp4': 'video/mp4',
    'mkv': 'video/x-matroska',
  };

  Future<CoreBoundedUploadSource?> pick() async {
    try {
      final file = await _pick();
      if (file == null) return null;
      if (file.name.isEmpty ||
          file.name.length > 255 ||
          file.name.contains(RegExp(r'[/\\\x00-\x1f\x7f]')) ||
          file.declaredLength < 1 ||
          file.declaredLength > CoreBoundedDownloadApi.maxBlobBytes) {
        throw const CoreBoundedDownloadException('file_access_failed');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.chunks) {
        if (builder.length + chunk.length > file.declaredLength ||
            builder.length + chunk.length >
                CoreBoundedDownloadApi.maxBlobBytes) {
          throw const CoreBoundedDownloadException('file_access_failed');
        }
        builder.add(chunk);
      }
      if (builder.length != file.declaredLength) {
        throw const CoreBoundedDownloadException('file_access_failed');
      }
      final separator = file.name.lastIndexOf('.');
      final extension = separator < 0
          ? ''
          : file.name.substring(separator + 1).toLowerCase();
      return CoreBoundedUploadSource(
        filename: file.name,
        contentType: _types[extension] ?? 'application/octet-stream',
        bytes: builder.takeBytes(),
      );
    } on CoreBoundedDownloadException {
      rethrow;
    } catch (_) {
      throw const CoreBoundedDownloadException('file_access_failed');
    }
  }
}
