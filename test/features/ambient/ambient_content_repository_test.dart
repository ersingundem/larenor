import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ambient/data/ambient_content_repository.dart';
import 'package:larenor/features/ambient/domain/ambient_content.dart';

void main() {
  late Directory parent;
  late AmbientContentRepository repository;

  setUp(() async {
    parent = await Directory.systemTemp.createTemp('larenor-ambient-content-');
    repository = AmbientContentRepository(
      directory: () async => Directory('${parent.path}/content'),
    );
  });
  tearDown(() async => parent.delete(recursive: true));

  test(
    'imports bounded PDF/video and web sources without retaining picker paths',
    () async {
      final pdf = Uint8List.fromList('%PDF-1.7\nbody\n%%EOF'.codeUnits);
      final video = Uint8List.fromList(<int>[
        0,
        0,
        0,
        20,
        ...'ftyp'.codeUnits,
        ...'isom'.codeUnits,
        0,
        0,
        0,
        0,
      ]);
      await repository.importLocal(
        AmbientContentKind.pdf,
        Stream.value(pdf),
        isCurrent: () => true,
      );
      await repository.importLocal(
        AmbientContentKind.video,
        Stream.value(video),
        isCurrent: () => true,
      );
      await repository.addWeb(
        'https://panel.example/status',
        isCurrent: () => true,
      );

      final items = await repository.list();
      expect(items.map((e) => e.kind), [
        AmbientContentKind.pdf,
        AmbientContentKind.video,
        AmbientContentKind.web,
      ]);
      expect(items.last.webUrl, 'https://panel.example/status');
      expect(
        items.every((e) => !e.toJson().toString().contains(parent.path)),
        isTrue,
      );
      expect(await repository.readLocal(items.first), pdf);
    },
  );

  test(
    'rejects secret-bearing web URLs, wrong formats, overflow and stale writes',
    () async {
      for (final url in <String>[
        'http://panel.example/',
        'https://user:pass@panel.example/',
        'https://panel.example/?token=secret',
        'https://panel.example/#secret',
      ]) {
        await expectLater(
          repository.addWeb(url, isCurrent: () => true),
          throwsA(isA<AmbientContentException>()),
        );
      }
      await expectLater(
        repository.importLocal(
          AmbientContentKind.pdf,
          Stream.value([1, 2, 3]),
          isCurrent: () => true,
        ),
        throwsA(isA<AmbientContentException>()),
      );
      await repository.importLocal(
        AmbientContentKind.pdf,
        Stream.value('%PDF-1.7\n%%EOF'.codeUnits),
        isCurrent: () => false,
      );
      expect(await repository.list(), isEmpty);
    },
  );

  test(
    'tampered entry is skipped while later verified content remains readable',
    () async {
      final first = Uint8List.fromList('%PDF-1.7\none\n%%EOF'.codeUnits);
      final second = Uint8List.fromList('%PDF-1.7\ntwo\n%%EOF'.codeUnits);
      await repository.importLocal(
        AmbientContentKind.pdf,
        Stream.value(first),
        isCurrent: () => true,
      );
      await repository.importLocal(
        AmbientContentKind.pdf,
        Stream.value(second),
        isCurrent: () => true,
      );
      final items = await repository.list();
      await File('${parent.path}/content/${items.first.id}.pdf')
          .writeAsBytes([1, 2, 3]);
      await expectLater(
        repository.readLocal(items.first),
        throwsA(isA<AmbientContentException>()),
      );
      expect(await repository.readLocal(items.last), second);
    },
  );
}
