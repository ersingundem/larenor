import 'dart:typed_data';
import 'package:larenor/features/home_scope/presentation/core_layout_archive_file_access.dart';

/// Test-only file adapter. Safe runtime RED stub: no native or persistent IO.
class SyntheticCoreArchiveFiles extends CoreLayoutArchiveFileAccess {
  int get picks => 0;
  int get saves => 0;
  Uint8List? get savedCiphertext => null;
  void queuePick(Uint8List? ciphertext) {}
  @override Future<Uint8List?> pick() async => null;
  @override Future<Uri?> save(Uint8List bytes) async => null;
}
