import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/camera_search/data/camera_clip_player.dart';
import 'package:larenor/features/camera_search/data/clip/camera_clip_source.dart';
import 'package:larenor/features/camera_search/domain/camera_search_models.dart';
import 'package:larenor/features/camera_search/presentation/camera_clip_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

class _Player implements CameraClipPlayer {
  final plays = StreamController<bool>.broadcast();
  final buffers = StreamController<bool>.broadcast();
  final positions = StreamController<Duration>.broadcast();
  final durations = StreamController<Duration>.broadcast();
  final failures = StreamController<String>.broadcast();
  String? opened;
  bool disposed = false;
  int toggles = 0;
  Duration? sought;
  @override
  Stream<bool> get playing => plays.stream;
  @override
  Stream<bool> get buffering => buffers.stream;
  @override
  Stream<Duration> get position => positions.stream;
  @override
  Stream<Duration> get duration => durations.stream;
  @override
  Stream<String> get errors => failures.stream;
  @override
  Widget surface() => const ColoredBox(color: CupertinoColors.black);
  @override
  Future<void> open(String uri) async {
    opened = uri;
    durations.add(const Duration(seconds: 12));
    plays.add(true);
  }

  @override
  Future<void> toggle() async {
    toggles++;
    plays.add(false);
  }

  @override
  Future<void> seek(Duration value) async {
    sought = value;
    positions.add(value);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await Future.wait([
      plays.close(),
      buffers.close(),
      positions.close(),
      durations.close(),
      failures.close(),
    ]);
  }
}

class _Source implements CameraClipSource {
  bool disposed = false;
  @override
  String get uri => 'file:///app-private/video.mp4';
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

CameraSearchEvidence get evidence => CameraSearchEvidence(
  coreId: 'a' * 32,
  homeId: 'b' * 32,
  cameraId: 'c' * 32,
  clipId: 'd' * 32,
  eventId: 'e' * 32,
  captureRevision: 1,
  indexRevision: 1,
  capturedAt: DateTime.utc(2026, 9, 30),
);
Widget app(Widget screen, {double scale = 1}) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: screen,
);

void main() {
  testWidgets(
    'actual command interface, Space, seek and close dispose private source',
    (tester) async {
      final player = _Player(), source = _Source();
      final bytes = Uint8List.fromList(List.filled(32, 8));
      bool closed = false;
      await tester.pumpWidget(
        app(
          CameraClipScreen(
            evidence: evidence,
            load: () async => bytes,
            isCurrent: () => true,
            onClose: () => closed = true,
            sourceFactory: (value) async {
              expect(value, orderedEquals(List.filled(32, 8)));
              return source;
            },
            playerFactory: () => player,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(player.opened, source.uri);
      expect(bytes, orderedEquals(List.filled(32, 0)));
      await tester.ensureVisible(
        find.byKey(const ValueKey('camera-clip-play')),
      );
      await tester.tap(find.byKey(const ValueKey('camera-clip-play')));
      await tester.pump();
      expect(player.toggles, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(player.toggles, 2);
      final slider = tester.widget<CupertinoSlider>(
        find.byKey(const ValueKey('camera-clip-seek')),
      );
      slider.onChanged!(5000);
      slider.onChangeEnd!(5000);
      await tester.pump();
      expect(player.sought, const Duration(seconds: 5));
      await tester.tap(find.text('Results'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(player.disposed, isTrue);
      expect(source.disposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retired late response is wiped before native source or player exists',
    (tester) async {
      final ready = Completer<Uint8List>();
      bool current = true, created = false;
      final bytes = Uint8List.fromList(List.filled(32, 8));
      await tester.pumpWidget(
        app(
          CameraClipScreen(
            evidence: evidence,
            load: () => ready.future,
            isCurrent: () => current,
            onClose: () {},
            sourceFactory: (_) async {
              created = true;
              return _Source();
            },
            playerFactory: _Player.new,
          ),
        ),
      );
      current = false;
      await tester.pump(const Duration(seconds: 1));
      ready.complete(bytes);
      await tester.pumpAndSettle();
      expect(created, isFalse);
      expect(bytes, orderedEquals(List.filled(32, 0)));
      expect(find.textContaining('no longer available'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'foreground loss disposes playback and text remains reachable at 200 percent',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final player = _Player(), source = _Source();
      await tester.pumpWidget(
        app(
          CameraClipScreen(
            evidence: evidence,
            load: () async => Uint8List(32),
            isCurrent: () => true,
            onClose: () {},
            sourceFactory: (_) async => source,
            playerFactory: () => player,
          ),
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(player.disposed, isTrue);
      expect(source.disposed, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
