import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/ssh/sftp_file_access.dart';
import 'package:larenor/features/remote_access/ssh/sftp_models.dart';

void main() {
  test('bounded upload reader freezes exact selected bytes', () async {
    final upload = await SftpFileAccess.collectUpload(
      name: 'notes.txt',
      declaredLength: 5,
      chunks: Stream.fromIterable([
        Uint8List.fromList([1, 2]),
        Uint8List.fromList([3, 4, 5]),
      ]),
    );
    expect(upload.name, 'notes.txt');
    expect(upload.bytes, [1, 2, 3, 4, 5]);
  });

  test('upload reader rejects length mismatch and limit overflow', () async {
    expect(
      SftpFileAccess.collectUpload(
        name: 'short.bin',
        declaredLength: 4,
        chunks: Stream.value(Uint8List.fromList([1, 2])),
      ),
      throwsA(isA<SftpFailure>()),
    );
    expect(
      SftpFileAccess.collectUpload(
        name: 'large.bin',
        declaredLength: sftpMaxTransferBytes + 1,
        chunks: const Stream.empty(),
      ),
      throwsA(isA<SftpFailure>()),
    );
  });

  test('cancelled picker and save remain explicit no-op outcomes', () async {
    final access = SftpFileAccess(
      pickFile: () async => null,
      saveFile: (_, _) async => null,
    );
    expect(await access.pickUpload(), isNull);
    expect(await access.saveDownload('result.bin', Uint8List(1)), isFalse);
  });
}
