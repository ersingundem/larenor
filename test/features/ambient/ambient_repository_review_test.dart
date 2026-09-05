import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/ambient/data/ambient_repository.dart';

/// Synthetic bytes and private temporary files only. The injected normalizer
/// isolates persistence and cancellation from native image decoder timing.
void main() {
  late Directory root;
  late AmbientRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('larenor-ambient-review-');
    repository = AmbientRepository(
      directory: () async => root,
      normalize: (value) async => value,
    );
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'revocation after manifest staging preserves old entries and photo files',
    () async {
      final photo = Uint8List.fromList([1, 2, 3]);
      await repository.importPhoto(photo, isCurrent: () => true);
      final ids = await repository.list();
      final staging = File('${root.path}/library.tmp');
      var revoked = false;

      // Use the observable staging boundary, not sleeps or a count of internal
      // isCurrent calls. Once staging is written this lease is no longer valid.
      await repository.replaceOrder(
        [],
        expected: ids,
        isCurrent: () {
          if (staging.existsSync()) revoked = true;
          return !revoked;
        },
      );

      expect(revoked, isTrue);
      expect(await repository.list(), ids);
      expect(await repository.readPhoto(ids.single), photo);
    },
  );

  test('queued reorder freezes both selected and expected lists before awaiting storage', () async {
    await repository.importPhoto(
      Uint8List.fromList([1, 2, 3]),
      isCurrent: () => true,
    );
    await repository.importPhoto(
      Uint8List.fromList([4, 5, 6]),
      isCurrent: () => true,
    );
    final photos = await repository.list();
    final selected = photos.reversed.toList();
    final expected = photos.toList();
    final release = Completer<void>();
    final started = Completer<void>();
    final blocker = ConfigurationWrites.run(() {
      started.complete();
      return release.future;
    });
    await started.future;

    final reorder = repository.replaceOrder(
      selected,
      expected: expected,
      isCurrent: () => true,
    );
    selected.clear();
    expected.clear();
    release.complete();
    await blocker;
    await reorder;

    expect(await repository.list(), photos.reversed.toList());
    for (final id in photos) {
      expect(await File('${root.path}/$id.png').exists(), isTrue);
    }
  });

  test(
    'queued import preserves selected bytes when the caller reuses its buffer',
    () async {
      final release = Completer<void>();
      final started = Completer<void>();
      final blocker = ConfigurationWrites.run(() {
        started.complete();
        return release.future;
      });
      await started.future;
      final source = Uint8List.fromList([1, 2, 3]);
      final import = repository.importPhoto(source, isCurrent: () => true);
      source[0] = 9;
      release.complete();
      await blocker;
      await import;

      final ids = await repository.list();
      expect(await repository.readPhoto(ids.single), [1, 2, 3]);
    },
  );

  test('a stuck cancellation cannot indefinitely extend the stream deadline', () {
    fakeAsync((clock) {
      final cancel = Completer<void>();
      var cancellationStarted = false;
      final source = StreamController<List<int>>(
        onCancel: () {
          cancellationStarted = true;
          return cancel.future;
        },
      );
      var done = false;
      Object? failure;
      AmbientRepository.boundedBytes(source.stream, 100).then<void>(
        (_) {
          done = true;
        },
        onError: (Object error) {
          failure = error;
          done = true;
        },
      );

      clock.elapse(const Duration(seconds: 15));
      clock.flushMicrotasks();
      expect(cancellationStarted, isTrue);
      clock.elapse(const Duration(seconds: 2));
      clock.flushMicrotasks();
      expect(done, isTrue, reason: '15-second read plus bounded cleanup');
      expect(failure, isNotNull);

      // A late native/provider completion must not replace the failure or emit
      // an unhandled asynchronous error after the caller has already returned.
      final originalFailure = failure;
      cancel.complete();
      clock.flushMicrotasks();
      expect(failure, same(originalFailure));
      source.close();
      clock.flushMicrotasks();
    });
  });
}
