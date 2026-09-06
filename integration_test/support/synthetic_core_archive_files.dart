import 'dart:collection';
import 'dart:typed_data';

import 'package:larenor/features/home_scope/presentation/core_layout_archive_file_access.dart';

/// Disposable test-only file selection/save; no OS file, plaintext model,
/// credential, network or restore operation. Callers supply codec ciphertext.
/// This adapter does not authenticate ciphertext or grant archive authority.
class SyntheticCoreArchiveFiles extends CoreLayoutArchiveFileAccess {
  final _selections = Queue<Uint8List?>();
  Uint8List? _saved;
  int _picks = 0, _saves = 0;
  int get picks => _picks;
  int get saves => _saves;
  Uint8List? get savedCiphertext =>
      _saved == null ? null : Uint8List.fromList(_saved!);

  void _check(Uint8List bytes) {
    if (bytes.isEmpty ||
        bytes.length > CoreLayoutArchiveFileAccess.maxFileBytes) {
      throw const CoreLayoutArchiveFileException();
    }
  }

  void queuePick(Uint8List? ciphertext) {
    if (_selections.length >= 4) throw const CoreLayoutArchiveFileException();
    if (ciphertext != null) _check(ciphertext);
    _selections.add(ciphertext == null ? null : Uint8List.fromList(ciphertext));
  }

  @override
  Future<Uint8List?> pick() async {
    _picks++;
    if (_selections.isEmpty) return null;
    return _selections.removeFirst();
  }

  @override
  Future<Uri?> save(Uint8List bytes) async {
    _check(bytes);
    _saved = Uint8List.fromList(bytes);
    _saves++;
    return Uri.parse('memory:core-room-archive');
  }
}
