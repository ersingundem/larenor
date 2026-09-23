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

  test('save clears its owned export buffer after success', () async {
    Uint8List? exported;
    final source = Uint8List.fromList([1, 2, 3]);
    final access = SftpFileAccess(
      saveFile: (_, bytes) async {
        exported = bytes;
        expect(bytes, [1, 2, 3]);
        return Uri.file('/tmp/result.bin');
      },
    );

    expect(await access.saveDownload('result.bin', source), isTrue);
    expect(source, [1, 2, 3]);
    expect(exported, [0, 0, 0]);
  });

  test('save clears its owned export buffer after failure', () async {
    Uint8List? exported;
    final source = Uint8List.fromList([7, 8]);
    final access = SftpFileAccess(
      saveFile: (_, bytes) async {
        exported = bytes;
        throw StateError('storage failed');
      },
    );

    await expectLater(
      access.saveDownload('result.bin', source),
      throwsA(
        isA<SftpFailure>().having(
          (failure) => failure.code,
          'code',
          'file_access_failed',
        ),
      ),
    );
    expect(source, [7, 8]);
    expect(exported, [0, 0]);
  });

  test('upload reader maps stream failures without leaking details', () async {
    final controller = StreamController<Uint8List>();
    final future = SftpFileAccess.collectUpload(
      name: 'partial.bin',
      declaredLength: 2,
      chunks: controller.stream,
    );
    controller.add(Uint8List.fromList([1]));
    controller.addError(StateError('provider detail'));
    await controller.close();

    await expectLater(
      future,
      throwsA(
        isA<SftpFailure>().having(
          (failure) => failure.code,
          'code',
          'file_access_failed',
        ),
      ),
    );
  });
}
