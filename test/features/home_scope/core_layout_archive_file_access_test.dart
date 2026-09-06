import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_scope/presentation/core_layout_archive_file_access.dart';

final class _File extends PlatformFile {
  _File(this.size, this.chunks, {this.filename = 'rooms.larenor-core-layout'});
  final int size;
  final List<Uint8List> chunks;
  final String filename;
  int reads = 0;
  @override
  String get name => filename;
  @override
  Uri get uri => Uri.parse('content://synthetic/picked');
  @override
  Never get xFile => throw UnsupportedError('not used');
  @override
  Future<int> length() async => size;
  @override
  Future<Uint8List> readAsBytes() async => throw UnsupportedError('not used');
  @override
  Stream<Uint8List> readAsByteStream() async* {
    for (final c in chunks) {
      reads++;
      yield c;
    }
  }
}

void main() {
  final failure = throwsA(isA<CoreLayoutArchiveFileException>());
  test('cancel performs no file reads and no save', () async {
    expect(
      await CoreLayoutArchiveFileAccess(pickFile: () async => null).pick(),
      isNull,
    );
  });
  test('bounded stream is returned exactly', () async {
    final file = _File(3, [
      Uint8List.fromList([1]),
      Uint8List.fromList([2, 3]),
    ]);
    expect(
      await CoreLayoutArchiveFileAccess(pickFile: () async => file).pick(),
      [1, 2, 3],
    );
    expect(file.reads, 2);
  });
  for (final name in [
    'other.larenor-vault',
    'no-extension',
    'x.LARENOR-CORE-LAYOUT',
  ]) {
    test('wrong extension $name never reads bytes', () async {
      final file = _File(1, [Uint8List(1)], filename: name);
      await expectLater(
        CoreLayoutArchiveFileAccess(pickFile: () async => file).pick(),
        failure,
      );
      expect(file.reads, 0);
    });
  }
  for (final size in [-1, 0, CoreLayoutArchiveFileAccess.maxFileBytes + 1]) {
    test('invalid declared length $size before stream', () async {
      final file = _File(size, [Uint8List(1)]);
      await expectLater(
        CoreLayoutArchiveFileAccess(pickFile: () async => file).pick(),
        failure,
      );
      expect(file.reads, 0);
    });
  }
  test('lying length cannot bypass stream limit', () async {
    final file = _File(1, [
      Uint8List(CoreLayoutArchiveFileAccess.maxFileBytes),
      Uint8List(1),
      Uint8List(1),
    ]);
    await expectLater(
      CoreLayoutArchiveFileAccess(pickFile: () async => file).pick(),
      failure,
    );
    expect(file.reads, 2);
  });
  test('exact three MiB encrypted boundary is accepted', () async {
    final file = _File(CoreLayoutArchiveFileAccess.maxFileBytes, [
      Uint8List(CoreLayoutArchiveFileAccess.maxFileBytes),
    ]);
    expect(
      (await CoreLayoutArchiveFileAccess(
        pickFile: () async => file,
      ).pick())!.length,
      CoreLayoutArchiveFileAccess.maxFileBytes,
    );
  });
  test('declared length must match completed stream', () async {
    final file = _File(3, [Uint8List(2)]);
    await expectLater(
      CoreLayoutArchiveFileAccess(pickFile: () async => file).pick(),
      failure,
    );
  });
  test(
    'save freezes encrypted bytes, fixed extension and cancellation',
    () async {
      final original = Uint8List.fromList([1, 2, 3]);
      final adapter = CoreLayoutArchiveFileAccess(
        saveFile: (bytes, name) async {
          original[0] = 9;
          expect(bytes, [1, 2, 3]);
          expect(name, 'larenor-rooms.larenor-core-layout');
          return null;
        },
      );
      expect(await adapter.save(original), isNull);
    },
  );
  test('save success reports OS chosen URI', () async {
    final uri = Uri.parse('content://synthetic/saved');
    expect(
      await CoreLayoutArchiveFileAccess(saveFile: (_, _) async => uri)
          .save(Uint8List(1)),
      uri,
    );
  });
  for (final size in [0, CoreLayoutArchiveFileAccess.maxFileBytes + 1]) {
    test('save rejects $size before OS dispatch', () async {
      var calls = 0;
      await expectLater(
        CoreLayoutArchiveFileAccess(
          saveFile: (_, _) async {
            calls++;
            return null;
          },
        ).save(Uint8List(size)),
        failure,
      );
      expect(calls, 0);
    });
  }
  test('OS errors are static and do not expose path', () async {
    await expectLater(
      CoreLayoutArchiveFileAccess(
        pickFile: () async => throw StateError('/private/synthetic'),
      ).pick(),
      failure,
    );
    await expectLater(
      CoreLayoutArchiveFileAccess(
        saveFile: (_, _) async => throw StateError('/private/synthetic'),
      ).save(Uint8List(1)),
      failure,
    );
  });
}
