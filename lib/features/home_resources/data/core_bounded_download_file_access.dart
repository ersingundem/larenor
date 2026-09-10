import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_bounded_download_api.dart';

typedef CoreBlobSave = Future<Uri?> Function(
  String filename,
  String contentType,
  Uint8List bytes,
);

final coreBoundedDownloadFileAccessProvider =
    Provider<CoreBoundedDownloadFileAccess>(
      (_) => CoreBoundedDownloadFileAccess(),
    );

/// Sends only fully framed, length- and digest-verified bytes to Android's SAF
/// create-document flow. Network partials never receive a filesystem path.
final class CoreBoundedDownloadFileAccess {
  CoreBoundedDownloadFileAccess({CoreBlobSave? save})
    : _save =
          save ??
          ((filename, contentType, bytes) => FilePicker.saveFile(
            fileName: filename,
            bytes: bytes,
            mimeType: contentType,
          ));
  final CoreBlobSave _save;

  Future<bool> publish(CoreBoundedBlob blob, String resourceId) async {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(resourceId) ||
        blob.bytes.isEmpty ||
        blob.bytes.length > CoreBoundedDownloadApi.maxBlobBytes) {
      throw const CoreBoundedDownloadException('file_access_failed');
    }
    try {
      final frozen = Uint8List.fromList(blob.bytes);
      return await _save(
            'larenor-resource-$resourceId.bin',
            blob.contentType,
            frozen,
          ) !=
          null;
    } catch (_) {
      throw const CoreBoundedDownloadException('file_access_failed');
    }
  }
}
