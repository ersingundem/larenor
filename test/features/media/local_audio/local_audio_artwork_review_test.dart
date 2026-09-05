import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/local_audio/data/local_audio_artwork_file_access.dart';
import 'package:larenor/features/media/local_audio/domain/local_audio_models.dart';

import 'local_audio_artwork_fixture.dart';

void main() {
  test('artwork stream cancellation cannot keep a timed-out picker operation pending', () {
    fakeAsync((clock) {
      final cancelled = Completer<void>();
      var cancellationStarted = false;
      final input = StreamController<List<int>>(
        onCancel: () {
          cancellationStarted = true;
          return cancelled.future;
        },
      );
      var completed = false;
      Object? failure;
      LocalAudioArtworkFileAccess.readBounded(
        input.stream,
        declaredLength: 8,
      ).then<void>(
        (_) {
          completed = true;
        },
        onError: (Object error) {
          failure = error;
          completed = true;
        },
      );
      clock.elapse(const Duration(seconds: 10));
      clock.flushMicrotasks();
      expect(cancellationStarted, isTrue);
      clock.elapse(const Duration(seconds: 2));
      clock.flushMicrotasks();
      expect(
        completed,
        isTrue,
        reason: 'Total read deadline plus bounded cleanup',
      );
      expect(failure, isNotNull);
      cancelled.complete();
      clock.flushMicrotasks();
      input.close();
      clock.flushMicrotasks();
    });
  });

  test(
    'slow-drip artwork input has one total deadline and no automatic retry',
    () {
      fakeAsync((clock) {
        final input = StreamController<List<int>>();
        var completed = false;
        Object? failure;
        LocalAudioArtworkFileAccess.readBounded(
          input.stream,
          declaredLength: 8,
        ).then<void>(
          (_) => completed = true,
          onError: (Object error) {
            failure = error;
            completed = true;
          },
        );
        for (var i = 0; i < 9; i++) {
          clock.elapse(const Duration(seconds: 1));
          input.add([137]);
          clock.flushMicrotasks();
        }
        expect(completed, isFalse);
        clock.elapse(const Duration(seconds: 1));
        clock.flushMicrotasks();
        expect(completed, isTrue);
        expect(failure, isA<TimeoutException>());
        input.close();
        clock.flushMicrotasks();
        expect(clock.nonPeriodicTimerCount, 0);
      });
    },
  );

  test('provider buffers are copied before a provider reuses them', () {
    fakeAsync((clock) {
      final original = artworkJpeg();
      final reused = Uint8List.fromList(original);
      final input = StreamController<List<int>>();
      Uint8List? result;
      LocalAudioArtworkFileAccess.readBounded(
        input.stream,
        declaredLength: reused.length,
      ).then((value) => result = value);
      input.add(reused);
      clock.flushMicrotasks();
      reused.fillRange(0, reused.length, 0);
      input.close();
      clock.flushMicrotasks();
      expect(result, original);
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  test('input failure is preserved when cleanup fails', () async {
    final input = StreamController<List<int>>(
      onCancel: () =>
          Future<void>.error(StateError('synthetic cleanup failure')),
    );
    final result = LocalAudioArtworkFileAccess.readBounded(
      input.stream,
      declaredLength: 8,
    );
    final checked = expectLater(result, throwsA(isA<LocalAudioException>()));
    input.add(Uint8List(LocalAudioArtwork.maxInputBytes + 1));
    await checked;
    await input.close();
  });
}
