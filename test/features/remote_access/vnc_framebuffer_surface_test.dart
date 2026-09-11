import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/vnc_framebuffer_surface.dart';

VncRawFrame _frame(int sequence, {int width = 2, int height = 2}) =>
    VncRawFrame.fromChannel({
      'schemaVersion': 1,
      'sequence': sequence,
      'width': width,
      'height': height,
      'stride': width * 4,
      'pixelFormat': 'rgba8888',
      'pixels': Uint8List.fromList(
        List<int>.generate(width * height * 4, (index) => index % 256),
      ),
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bounded decoder rejects malformed frames and wipes owned bytes',
    () async {
      final raw = _frame(1);
      final owned = raw.debugOwnedPixels;
      final decoded = await const VncFlutterFrameDecoder().decode(raw);
      expect(decoded.image.width, 2);
      expect(decoded.image.height, 2);
      expect(owned, everyElement(0));
      decoded.dispose();
      for (final bad in [
        {..._frameMap(), 'stride': 7},
        {..._frameMap(), 'pixels': Uint8List(15)},
        {..._frameMap(), 'pixelFormat': 'bgra8888'},
        {..._frameMap(), 'future': true},
      ]) {
        expect(
          () => VncRawFrame.fromChannel(bad),
          throwsA(isA<VncSurfaceException>()),
        );
      }
    },
  );

  test('scale and letterbox map only visible remote coordinates', () {
    final transform = VncViewportTransform.fit(
      const Size(1280, 720),
      const Size(1000, 1000),
    );
    expect(transform.destination.left, closeTo(0, .01));
    expect(transform.destination.top, closeTo(218.75, .01));
    expect(transform.destination.width, closeTo(1000, .01));
    expect(transform.destination.height, closeTo(562.5, .01));
    expect(transform.normalize(const Offset(500, 500)), const Offset(.5, .5));
    expect(transform.normalize(const Offset(500, 100)), isNull);
  });

  test(
    'one frame stays backpressured until explicit presentation ack',
    () async {
      final sink = _Sink();
      final controller = VncFramebufferController(
        sink: sink,
        isCurrent: () => true,
        isForeground: () => true,
        clipboardSupported: false,
      );
      addTearDown(controller.dispose);
      await controller.offer(_frame(1));
      expect(controller.renderedFrame?.sequence, 1);
      await expectLater(
        controller.offer(_frame(2)),
        throwsA(surfaceFailure('busy')),
      );
      expect(sink.acks, isEmpty);
      await controller.acknowledgePresented();
      expect(sink.acks, [1]);
      await controller.offer(_frame(2));
      expect(controller.renderedFrame?.sequence, 2);
      await controller.acknowledgePresented();
      expect(sink.acks, [1, 2]);
    },
  );

  test(
    'input is single-flight, clipboard opt-in, and retirement is terminal',
    () async {
      final sink = _Sink();
      var foreground = true;
      final controller = VncFramebufferController(
        sink: sink,
        isCurrent: () => true,
        isForeground: () => foreground,
        clipboardSupported: true,
      );
      addTearDown(controller.dispose);
      expect(controller.clipboardEnabled, isFalse);
      expect(
        () => controller.sendClipboard('Merhaba'),
        throwsA(surfaceFailure('clipboardDisabled')),
      );
      controller.setClipboardEnabled(true);
      sink.inputGate = Completer<void>();
      final first = controller.key(4, true);
      await expectLater(
        controller.key(4, false),
        throwsA(surfaceFailure('busy')),
      );
      expect(sink.inputs, hasLength(1));
      sink.inputGate!.complete();
      await first;
      sink.inputGate = null;
      await controller.sendClipboard('Merhaba dünya');
      expect(sink.inputs.last, {'kind': 'clipboard', 'text': 'Merhaba dünya'});
      foreground = false;
      await controller.synchronize();
      expect(sink.cancels, 1);
      await expectLater(
        controller.key(5, true),
        throwsA(surfaceFailure('retired')),
      );
      expect(sink.inputs, hasLength(2));
    },
  );

  test('route loss cancels once and rejects later frames', () async {
    final sink = _Sink();
    var current = true;
    final controller = VncFramebufferController(
      sink: sink,
      isCurrent: () => current,
      isForeground: () => true,
      clipboardSupported: false,
    );
    addTearDown(controller.dispose);
    await controller.offer(_frame(1));
    await controller.acknowledgePresented();
    current = false;
    await controller.synchronize();
    expect(controller.phase, VncSurfacePhase.retired);
    expect(controller.renderedFrame, isNull);
    expect(sink.cancels, 1);
    await expectLater(
      controller.offer(_frame(2)),
      throwsA(surfaceFailure('retired')),
    );
    expect(sink.cancels, 1);
  });

  testWidgets('tablet and DeX surface is accessible and cleans on background', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final sink = _Sink();
    final controller = VncFramebufferController(
      sink: sink,
      isCurrent: () => true,
      isForeground: () => true,
      clipboardSupported: true,
    );
    addTearDown(controller.dispose);
    var sequence = 1;
    for (final width in [600.0, 1280.0]) {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        CupertinoApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 800),
              textScaler: const TextScaler.linear(2),
            ),
            child: VncFramebufferSurface(
              controller: controller,
              semanticsLabel: 'Remote desktop',
            ),
          ),
        ),
      );
      await tester.runAsync(() => controller.offer(_frame(sequence)));
      await tester.pump();
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp('Remote desktop')), findsWidgets);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('vnc-clipboard-toggle')))
            .height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
      expect(sink.acks.last, sequence);
      if (sequence == 1) {
        await tester.tap(find.byKey(const ValueKey('vnc-framebuffer')));
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        expect(sink.inputs.any((event) => event['kind'] == 'pointer'), isTrue);
        expect(sink.inputs.any((event) => event['kind'] == 'key'), isTrue);
        await tester.tap(find.byKey(const ValueKey('vnc-clipboard-toggle')));
        expect(controller.clipboardEnabled, isTrue);
      }
      sequence++;
    }
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(sink.cancels, 1);
    semantics.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Map<String, Object?> _frameMap() => {
  'schemaVersion': 1,
  'sequence': 1,
  'width': 2,
  'height': 2,
  'stride': 8,
  'pixelFormat': 'rgba8888',
  'pixels': Uint8List(16),
};

Matcher surfaceFailure(String code) =>
    isA<VncSurfaceException>().having((error) => error.code, 'code', code);

class _Sink implements VncSurfaceSink {
  final acks = <int>[];
  final inputs = <Map<String, Object?>>[];
  int cancels = 0;
  Completer<void>? inputGate;

  @override
  Future<void> acknowledge(int sequence) async {
    acks.add(sequence);
  }

  @override
  Future<void> input(Map<String, Object?> event) async {
    inputs.add(Map.of(event));
    if (inputGate != null) await inputGate!.future;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }
}
