import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The OS owns the selected destination; encrypted bytes are never staged in a
/// temporary application file.
class ServerCoreBackupFileAccess {
  Future<Uri?> save(Uint8List bytes, String filename) => FilePicker.saveFile(
    fileName: filename,
    bytes: bytes,
    mimeType: 'application/vnd.larenor.core-backup',
  );
}

final serverCoreBackupFileAccessProvider = Provider<ServerCoreBackupFileAccess>(
  (ref) => ServerCoreBackupFileAccess(),
);
