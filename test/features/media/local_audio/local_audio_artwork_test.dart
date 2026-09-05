import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/local_audio/data/local_audio_artwork_file_access.dart';
import 'package:larenor/features/media/local_audio/data/local_audio_bridge.dart';
import 'package:larenor/features/media/local_audio/domain/local_audio_models.dart';
import 'package:larenor/features/media/local_audio/providers/local_audio_providers.dart';

import 'local_audio_artwork_fixture.dart';
import 'local_audio_models_test.dart';
import 'local_audio_ui_fixture.dart';

class ArtworkBridge extends FakeLocalAudioBridge {
  var artworkReads = 0;
  Completer<LocalAudioArtwork>? artGate;
  @override
  Future<LocalAudioArtwork> artwork({
    required String sourceId,
    required String artworkId,
  }) async {
    artworkReads++;
    return artGate == null ? artworkFixture() : await artGate!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel(LocalAudioBridge.methodChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(methods, null));
  test(
    'normalized bytes immutable, bounded, and channel rejects URI metadata',
    () {
      final raw = artworkJpeg();
      final art = LocalAudioArtwork.fromChannel({
        'bytes': raw,
        'width': 8,
        'height': 6,
      });
      raw.fillRange(0, raw.length, 0);
      expect(art.bytes.first, 255);
      expect(() => art.bytes[0] = 0, throwsUnsupportedError);
      expect(art.toString(), 'LocalAudioArtwork(redacted)');
      for (final packet in [
        {'bytes': artworkJpeg(), 'width': 513, 'height': 1},
        {
          'bytes': Uint8List(LocalAudioArtwork.maxOutputBytes + 1),
          'width': 1,
          'height': 1,
        },
        {
          'bytes': artworkJpeg(),
          'width': 8,
          'height': 6,
          'url': 'https://private?token=secret',
        },
        {
          'bytes': Uint8List.fromList([1, 2, 3]),
          'width': 8,
          'height': 6,
        },
      ]) {
        expect(
          () => LocalAudioArtwork.fromChannel(packet),
          throwsA(isA<LocalAudioException>()),
        );
      }
      final source = LocalAudioSource(
        id: 'station',
        uri: Uri.parse('https://radio.example/live'),
        mimeType: 'audio/mpeg',
        title: 'Station',
        artwork: art,
      );
      expect(source.toChannel()['artworkBytes'], art.bytes);
      expect(source.toString(), isNot(contains('255')));
    },
  );
  test(
    'snapshot cover requires exact source and opaque ID, no bytes or URL',
    () {
      expect(
        LocalAudioSnapshot.fromChannel(audioSnapshot()).artworkState,
        LocalAudioArtworkState.none,
      );
      final ready = {
        ...audioSnapshot(),
        'artworkState': 'ready',
        'artworkId': 'opaque-cover',
      };
      expect(LocalAudioSnapshot.fromChannel(ready).artworkId, 'opaque-cover');
      for (final bad in [
        {...ready, 'sourceId': null},
        {...ready, 'artworkId': null},
        {...ready, 'artworkId': 'https://example/image'},
        {...ready, 'artworkState': 'none'},
        {...ready, 'artworkState': 'download'},
        {...ready, 'artworkBytes': artworkJpeg()},
      ]) {
        expect(
          () => LocalAudioSnapshot.fromChannel(bad),
          throwsA(isA<LocalAudioException>()),
        );
      }
    },
  );
  test(
    'file stream is bounded even if declared length lies and stops consuming',
    () async {
      var chunksRead = 0;
      Stream<List<int>> stream() async* {
        chunksRead++;
        yield Uint8List(LocalAudioArtwork.maxInputBytes + 1);
        chunksRead++;
        yield artworkJpeg();
      }

      await expectLater(
        LocalAudioArtworkFileAccess.readBounded(stream(), declaredLength: 8),
        throwsA(isA<LocalAudioException>()),
      );
      expect(chunksRead, 1);
      final bytes = artworkJpeg();
      expect(
        await LocalAudioArtworkFileAccess.readBounded(
          Stream.fromIterable([bytes.sublist(0, 5), bytes.sublist(5)]),
          declaredLength: bytes.length,
        ),
        bytes,
      );
      await expectLater(
        LocalAudioArtworkFileAccess.readBounded(
          const Stream.empty(),
          declaredLength: LocalAudioArtwork.maxInputBytes + 1,
        ),
        throwsA(isA<LocalAudioException>()),
      );
    },
  );
  test('artwork prepare/read channel never starts playback and drops raw error details', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return {'bytes': artworkJpeg(), 'width': 8, 'height': 6};
    });
    final bridge = LocalAudioBridge(isAndroid: true);
    await bridge.prepareArtwork(artworkJpeg());
    await bridge.artwork(sourceId: 'station', artworkId: 'cover');
    expect(calls.map((e) => e.method), ['prepareArtwork', 'artwork']);
    expect(calls.first.arguments, isA<Uint8List>());
    expect(calls.last.arguments, {'sourceId': 'station', 'artworkId': 'cover'});
    await expectLater(
      bridge.prepareArtwork(Uint8List(2)),
      throwsA(isA<LocalAudioException>()),
    );
    expect(calls, hasLength(2));
    messenger.setMockMethodCallHandler(
      methods,
      (_) async => throw PlatformException(
        code: 'invalidArtwork',
        message: 'private/file/secret',
        details: artworkJpeg(),
      ),
    );
    try {
      await bridge.prepareArtwork(artworkJpeg());
      fail('Should reject');
    } on LocalAudioException catch (e) {
      expect(e.failure, LocalAudioFailure.invalidArtwork);
      expect(e.toString(), isNot(contains('secret')));
    }
    await expectLater(
      LocalAudioBridge(isAndroid: false).prepareArtwork(artworkJpeg()),
      throwsA(audioFailure(LocalAudioFailure.unsupported)),
    );
  });
  test(
    'in-transit image cannot outlive source replacement; stable ID reads once',
    () async {
      final bridge = ArtworkBridge();
      bridge.current = const LocalAudioSnapshot(
        supported: true,
        sourceId: 'station',
        artworkId: 'cover',
        artworkState: LocalAudioArtworkState.ready,
      );
      final container = ProviderContainer(
        overrides: [localAudioBridgeProvider.overrideWithValue(bridge)],
      );
      addTearDown(container.dispose);
      addTearDown(bridge.events.close);
      final provider = localAudioArtworkProvider((
        sourceId: 'station',
        artworkId: 'cover',
      ));
      final listener = container.listen(provider, (_, _) {});
      addTearDown(listener.close);
      expect(await container.read(provider.future), isA<LocalAudioArtwork>());
      expect(await container.read(provider.future), isA<LocalAudioArtwork>());
      expect(bridge.artworkReads, 1);
      bridge.artGate = Completer<LocalAudioArtwork>();
      container.invalidate(provider);
      final late = container.read(provider.future);
      bridge.current = const LocalAudioSnapshot(supported: true);
      final rejection = expectLater(late, throwsA(isA<LocalAudioException>()));
      bridge.artGate!.complete(artworkFixture());
      await rejection;
    },
  );
}
