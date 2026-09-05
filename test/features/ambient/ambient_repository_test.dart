import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ambient/data/ambient_repository.dart';
import 'package:larenor/features/ambient/domain/ambient_settings.dart';

void main() {
  group('ambient model', () {
    test('photo sharing is opt-in and every preference roundtrips', () {
      expect(const AmbientSettings().photosEnabled, isFalse);
      final settings = const AmbientSettings().copyWith(
        photosEnabled: true,
        showClock: false,
        showWeather: false,
        pixelShift: false,
        intervalSeconds: 120,
        fit: AmbientPhotoFit.cover,
      );
      expect(
        AmbientSettings.decode(settings.encode()).encode(),
        settings.encode(),
      );
    });
    for (final value in [
      {'version': 1.0},
      {'intervalSeconds': 1},
      {'photosEnabled': 'true'},
      {'fit': 'url'},
      {'url': 'https://invalid.example'},
    ]) {
      test('rejects invalid settings $value', () {
        final data = jsonDecode(
          const AmbientSettings().encode(),
        ) as Map<String, dynamic>;
        data.addAll(value);
        expect(
          () => AmbientSettings.decode(jsonEncode(data)),
          throwsA(isA<AmbientException>()),
        );
      });
    }
  });

  group('private selected-photo repository', () {
    late Directory parent;
    late Directory root;
    late AmbientRepository repository;
    final first = Uint8List.fromList([1, 2, 3]);
    final second = Uint8List.fromList([4, 5, 6]);
    setUp(() async {
      parent = await Directory.systemTemp.createTemp('larenor-ambient-test-');
      root = Directory('${parent.path}/library');
      repository = AmbientRepository(
        directory: () async => root,
        normalize: (bytes) async => bytes,
      );
    });
    tearDown(() async => parent.delete(recursive: true));

    test('initial read does not create directories', () async {
      expect(await repository.list(), isEmpty);
      expect(await root.exists(), isFalse);
    });
    test('import persists one canonical copy and duplicate is inert', () async {
      await repository.importPhoto(first, isCurrent: () => true);
      await repository.importPhoto(first, isCurrent: () => true);
      final ids = await repository.list();
      expect(ids, [sha256.convert(first).toString()]);
      expect(await repository.readPhoto(ids.single), first);
      expect((await root.list().toList()).length, 2);
    });
    test('expired selection never creates a file', () async {
      await repository.importPhoto(first, isCurrent: () => false);
      expect(await root.exists(), isFalse);
    });
    test('selection expiring during normalization is discarded', () async {
      final decode = Completer<Uint8List>();
      final started = Completer<void>();
      var current = true;
      repository = AmbientRepository(
        directory: () async => root,
        normalize: (_) {
          started.complete();
          return decode.future;
        },
      );
      final import = repository.importPhoto(first, isCurrent: () => current);
      await started.future;
      current = false;
      decode.complete(first);
      await import;
      expect(await root.exists(), isFalse);
    });
    test('reorder and remove affect only owned copies', () async {
      final original = File('${parent.path}/original.jpg');
      await original.writeAsBytes(first);
      await repository.importPhoto(first, isCurrent: () => true);
      await repository.importPhoto(second, isCurrent: () => true);
      final ids = await repository.list();
      await repository.replaceOrder(
        ids.reversed.toList(),
        expected: ids,
        isCurrent: () => true,
      );
      expect(await repository.list(), ids.reversed.toList());
      await repository.replaceOrder(
        [ids.last],
        expected: ids.reversed.toList(),
        isCurrent: () => true,
      );
      expect(await File('${root.path}/${ids.first}.png').exists(), isFalse);
      expect(await original.readAsBytes(), first);
      await expectLater(
        repository.readPhoto(ids.first),
        throwsA(isA<AmbientException>()),
      );
    });
    test('stale collection cannot reorder a replacement', () async {
      await repository.importPhoto(first, isCurrent: () => true);
      final old = await repository.list();
      await repository.importPhoto(second, isCurrent: () => true);
      await expectLater(
        repository.replaceOrder([], expected: old, isCurrent: () => true),
        throwsA(isA<AmbientException>()),
      );
      expect((await repository.list()).length, 2);
    });
    test('tampered image fails integrity check', () async {
      await repository.importPhoto(first, isCurrent: () => true);
      final id = (await repository.list()).single;
      await File('${root.path}/$id.png').writeAsBytes(second);
      await expectLater(
        repository.readPhoto(id),
        throwsA(isA<AmbientException>()),
      );
    });
    test(
      'corrupt manifest blocks mutations without replacing existing bytes',
      () async {
        await root.create();
        final manifest = File('${root.path}/library.json');
        await manifest.writeAsString('{broken');
        await expectLater(
          repository.importPhoto(first, isCurrent: () => true),
          throwsA(isA<AmbientException>()),
        );
        expect(await manifest.readAsString(), '{broken');
      },
    );
    test('foreign path IDs are never read', () async {
      for (final id in ['../original', 'a/b', 'https://server/photo', '']) {
        await expectLater(
          repository.readPhoto(id),
          throwsA(isA<AmbientException>()),
        );
      }
    });
    test('symlink at destination cannot overwrite original', () async {
      await root.create();
      final outside = File('${parent.path}/original.png');
      await outside.writeAsBytes(second);
      final id = sha256.convert(first).toString();
      await Link('${root.path}/$id.png').create(outside.path);
      await expectLater(
        repository.importPhoto(first, isCurrent: () => true),
        throwsA(isA<AmbientException>()),
      );
      expect(await outside.readAsBytes(), second);
    });
    test('24-photo quota rejects another import', () async {
      for (var i = 0; i < 24; i++) {
        await repository.importPhoto(
          Uint8List.fromList([i]),
          isCurrent: () => true,
        );
      }
      await expectLater(
        repository.importPhoto(Uint8List.fromList([99]), isCurrent: () => true),
        throwsA(isA<AmbientException>().having((e) => e.limit, 'limit', true)),
      );
      expect((await repository.list()).length, 24);
    });
    test('crash orphan cleanup preserves unrelated files', () async {
      await root.create();
      final orphan = File('${root.path}/${'a' * 64}.png');
      await orphan.writeAsBytes(first);
      final other = File('${root.path}/user-notes.txt');
      await other.writeAsString('keep');
      await repository.importPhoto(second, isCurrent: () => true);
      expect(await orphan.exists(), isFalse);
      expect(await other.readAsString(), 'keep');
    });
  });

  test('bounded stream aborts on overflow', () async {
    await expectLater(
      AmbientRepository.boundedBytes(
        Stream.fromIterable([
          [1, 2],
          [3, 4],
        ]),
        3,
      ),
      throwsA(isA<AmbientException>()),
    );
  });
  test('slow-drip stream still has a total deadline and is canceled', () {
    fakeAsync((async) {
      var canceled = false, failed = false;
      final stream = StreamController<List<int>>(
        onCancel: () => canceled = true,
      );
      AmbientRepository.boundedBytes(stream.stream, 100).then<void>(
        (_) {},
        onError: (_) {
          failed = true;
        },
      );
      for (var i = 0; i < 4; i++) {
        async.elapse(const Duration(seconds: 4));
        stream.add([1]);
        async.flushMicrotasks();
      }
      expect(failed, isTrue);
      expect(canceled, isTrue);
      stream.close();
    });
  });
  testWidgets(
    'normalizer decodes a real PNG, strips metadata and bounds output',
    (tester) async {
      await tester.runAsync(() async {
        final source = await File('assets/icon/app_icon.png').readAsBytes();
        final normalized = await AmbientRepository.normalizePhoto(source);
        expect(normalized.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        expect(
          normalized.length,
          lessThanOrEqualTo(AmbientRepository.maxPhotoBytes),
        );
        await expectLater(
          AmbientRepository.normalizePhoto(Uint8List.fromList([1, 2, 3])),
          throwsA(isA<AmbientException>()),
        );
      });
    },
  );
}
