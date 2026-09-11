import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vnc_native_bridge.dart';

class VncSurfaceException implements Exception {
  const VncSurfaceException(this.code);
  final String code;
  @override
  String toString() => 'VncSurfaceException($code)';
}

Never _reject(String code) => throw VncSurfaceException(code);

class VncRawFrame {
  VncRawFrame._(
    this.sequence,
    this.width,
    this.height,
    this.stride,
    this._pixels,
  );
  final int sequence, width, height, stride;
  Uint8List? _pixels;

  factory VncRawFrame.fromChannel(Object? raw) {
    const keys = {
      'schemaVersion',
      'sequence',
      'width',
      'height',
      'stride',
      'pixelFormat',
      'pixels',
    };
    if (raw is! Map ||
        raw.length != keys.length ||
        !keys.every(raw.containsKey) ||
        raw['schemaVersion'] != 1 ||
        raw['pixelFormat'] != 'rgba8888') {
      _reject('invalidFrame');
    }
    final sequence = raw['sequence'],
        width = raw['width'],
        height = raw['height'],
        stride = raw['stride'],
        pixels = raw['pixels'];
    if (sequence is! int ||
        sequence < 1 ||
        sequence > 0x1fffffffffffff ||
        width is! int ||
        width < 1 ||
        width > 8192 ||
        height is! int ||
        height < 1 ||
        height > 8192 ||
        stride is! int ||
        stride != width * 4 ||
        pixels is! Uint8List ||
        pixels.isEmpty ||
        pixels.length > maxBytes ||
        pixels.length != stride * height) {
      _reject('invalidFrame');
    }
    return VncRawFrame._(
      sequence,
      width,
      height,
      stride,
      Uint8List.fromList(pixels),
    );
  }

  @visibleForTesting
  Uint8List get debugOwnedPixels => _pixels ?? Uint8List(0);

  Uint8List takePixels() {
    final pixels = _pixels;
    if (pixels == null) _reject('frameConsumed');
    _pixels = null;
    return pixels;
  }

  void dispose() {
    _pixels?.fillRange(0, _pixels!.length, 0);
    _pixels = null;
  }

  static const maxBytes = 16 * 1024 * 1024;
}

class VncDecodedFrame {
  VncDecodedFrame({required this.sequence, required this.image});
  final int sequence;
  final ui.Image image;
  bool _disposed = false;
  Size get size => Size(image.width.toDouble(), image.height.toDouble());
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    image.dispose();
  }
}

abstract interface class VncFrameDecoder {
  Future<VncDecodedFrame> decode(VncRawFrame frame);
}

class VncFlutterFrameDecoder implements VncFrameDecoder {
  const VncFlutterFrameDecoder();

  @override
  Future<VncDecodedFrame> decode(VncRawFrame frame) async {
    final pixels = frame.takePixels();
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: frame.width,
        height: frame.height,
        rowBytes: frame.stride,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      final decoded = await codec.getNextFrame();
      if (decoded.image.width != frame.width ||
          decoded.image.height != frame.height) {
        decoded.image.dispose();
        _reject('invalidFrame');
      }
      return VncDecodedFrame(sequence: frame.sequence, image: decoded.image);
    } catch (error) {
      if (error is VncSurfaceException) rethrow;
      throw const VncSurfaceException('decodeFailed');
    } finally {
      pixels.fillRange(0, pixels.length, 0);
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
      frame.dispose();
    }
  }
}

class VncViewportTransform {
  const VncViewportTransform(this.destination);
  final Rect destination;

  factory VncViewportTransform.fit(Size remote, Size viewport) {
    if (remote.width <= 0 ||
        remote.height <= 0 ||
        viewport.width <= 0 ||
        viewport.height <= 0 ||
        !remote.width.isFinite ||
        !remote.height.isFinite ||
        !viewport.width.isFinite ||
        !viewport.height.isFinite) {
      _reject('invalidViewport');
    }
    final scale = math.min(
      viewport.width / remote.width,
      viewport.height / remote.height,
    );
    final size = Size(remote.width * scale, remote.height * scale);
    return VncViewportTransform(
      Rect.fromLTWH(
        (viewport.width - size.width) / 2,
        (viewport.height - size.height) / 2,
        size.width,
        size.height,
      ),
    );
  }

  Offset? normalize(Offset local) {
    if (!destination.contains(local)) return null;
    return Offset(
      ((local.dx - destination.left) / destination.width).clamp(0, 1),
      ((local.dy - destination.top) / destination.height).clamp(0, 1),
    );
  }
}

abstract interface class VncSurfaceSink {
  Future<void> acknowledge(int sequence);
  Future<void> input(Map<String, Object?> event);
  Future<void> cancel();
}

class VncBridgeSurfaceSink implements VncSurfaceSink {
  VncBridgeSurfaceSink(this.session);
  final VncBridgeSession session;
  @override
  Future<void> acknowledge(int sequence) => session.ackFrame(sequence);
  @override
  Future<void> input(Map<String, Object?> event) => session.input(event);
  @override
  Future<void> cancel() => session.retire();
}

enum VncSurfacePhase { active, retired, failed }

class VncFramebufferController extends ChangeNotifier {
  VncFramebufferController({
    required this.sink,
    required this.isCurrent,
    required this.isForeground,
    required this.clipboardSupported,
    this.decoder = const VncFlutterFrameDecoder(),
    this.decodeTimeout = const Duration(seconds: 5),
  });
  final VncSurfaceSink sink;
  final bool Function() isCurrent, isForeground;
  final bool clipboardSupported;
  final VncFrameDecoder decoder;
  final Duration decodeTimeout;
  VncSurfacePhase phase = VncSurfacePhase.active;
  VncDecodedFrame? renderedFrame;
  bool clipboardEnabled = false;
  bool _decoding = false, _awaitingAck = false, _inputBusy = false;
  bool _cancelled = false, _disposed = false;
  int _generation = 0, _expectedSequence = 1;

  bool get needsPresentationAck => _awaitingAck;

  bool get _owned {
    try {
      return !_disposed &&
          phase == VncSurfacePhase.active &&
          isCurrent() &&
          isForeground();
    } catch (_) {
      return false;
    }
  }

  Future<void> offer(VncRawFrame frame) async {
    if (!_owned) {
      frame.dispose();
      await retire();
      throw const VncSurfaceException('retired');
    }
    if (_decoding || _awaitingAck) {
      frame.dispose();
      throw const VncSurfaceException('busy');
    }
    if (frame.sequence != _expectedSequence) {
      frame.dispose();
      await retire();
      throw const VncSurfaceException('staleFrame');
    }
    final generation = _generation;
    _decoding = true;
    try {
      final decoded = await decoder.decode(frame).timeout(decodeTimeout);
      if (!_owned || generation != _generation) {
        decoded.dispose();
        await retire();
        throw const VncSurfaceException('retired');
      }
      renderedFrame?.dispose();
      renderedFrame = decoded;
      _awaitingAck = true;
      _publish();
    } on VncSurfaceException {
      await retire();
      rethrow;
    } on TimeoutException {
      frame.dispose();
      await retire();
      throw const VncSurfaceException('decodeTimedOut');
    } catch (_) {
      frame.dispose();
      await retire();
      throw const VncSurfaceException('decodeFailed');
    } finally {
      _decoding = false;
    }
  }

  Future<void> acknowledgePresented() async {
    final frame = renderedFrame;
    if (!_owned || !_awaitingAck || frame == null) {
      await retire();
      throw const VncSurfaceException('staleFrame');
    }
    try {
      await sink.acknowledge(frame.sequence);
      if (!_owned) {
        await retire();
        throw const VncSurfaceException('retired');
      }
      _awaitingAck = false;
      _expectedSequence++;
      _publish();
    } catch (error) {
      await retire();
      if (error is VncSurfaceException) rethrow;
      throw const VncSurfaceException('connectionFailed');
    }
  }

  void setClipboardEnabled(bool value) {
    if (!_owned) _reject('retired');
    if (value && !clipboardSupported) _reject('clipboardUnsupported');
    clipboardEnabled = value;
    _publish();
  }

  Future<void> key(int code, bool down) {
    if (code < 1 || code > 0xffff) _reject('invalidInput');
    return _send({'kind': 'key', 'code': code, 'down': down});
  }

  Future<bool> pointer(Offset local, Size viewport, int buttons) async {
    if (buttons < 0 || buttons > 31) _reject('invalidInput');
    final frame = renderedFrame;
    if (frame == null) return false;
    final point = VncViewportTransform.fit(
      frame.size,
      viewport,
    ).normalize(local);
    if (point == null) return false;
    await _send({
      'kind': 'pointer',
      'x': point.dx,
      'y': point.dy,
      'buttons': buttons,
    });
    return true;
  }

  Future<void> sendClipboard(String value) {
    if (!clipboardEnabled) _reject('clipboardDisabled');
    if (value.isEmpty || value.length > 65536 || value.contains('\u0000')) {
      _reject('invalidInput');
    }
    final encoded = utf8.encode(value);
    try {
      if (encoded.length > 65536) _reject('invalidInput');
    } finally {
      encoded.fillRange(0, encoded.length, 0);
    }
    return _send({'kind': 'clipboard', 'text': value});
  }

  Future<void> _send(Map<String, Object?> event) async {
    if (!_owned) {
      await retire();
      throw const VncSurfaceException('retired');
    }
    if (_inputBusy) throw const VncSurfaceException('busy');
    _inputBusy = true;
    try {
      await sink.input(event);
      if (!_owned) {
        await retire();
        throw const VncSurfaceException('retired');
      }
    } catch (error) {
      await retire();
      if (error is VncSurfaceException) rethrow;
      throw const VncSurfaceException('connectionFailed');
    } finally {
      _inputBusy = false;
    }
  }

  Future<void> synchronize() async {
    if (!_owned) await retire();
  }

  Future<void> retire() async {
    if (phase == VncSurfacePhase.retired) return;
    phase = VncSurfacePhase.retired;
    _generation++;
    _awaitingAck = false;
    clipboardEnabled = false;
    renderedFrame?.dispose();
    renderedFrame = null;
    _publish();
    if (_cancelled) return;
    _cancelled = true;
    try {
      await sink.cancel();
    } catch (_) {
      // Terminal cleanup is never retried and native details stay hidden.
    }
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    unawaited(retire());
    _disposed = true;
    super.dispose();
  }
}

class VncFramebufferSurface extends StatefulWidget {
  const VncFramebufferSurface({
    super.key,
    required this.controller,
    required this.semanticsLabel,
    this.clipboardLabel = 'Clipboard',
  });
  final VncFramebufferController controller;
  final String semanticsLabel, clipboardLabel;

  @override
  State<VncFramebufferSurface> createState() => _VncFramebufferSurfaceState();
}

class _VncFramebufferSurfaceState extends State<VncFramebufferSurface>
    with WidgetsBindingObserver {
  bool _ackScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(VncFramebufferSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_changed);
    unawaited(oldWidget.controller.retire());
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(widget.controller.retire());
    }
  }

  void _scheduleAck() {
    if (_ackScheduled || !widget.controller.needsPresentationAck) return;
    _ackScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (mounted && widget.controller.needsPresentationAck) {
          await widget.controller.acknowledgePresented();
        }
      } catch (_) {
        // Controller owns terminal cleanup and exposes no native diagnostics.
      } finally {
        _ackScheduled = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.controller.synchronize());
    });
    _scheduleAck();
    final controller = widget.controller;
    return Semantics(
      container: true,
      label: widget.semanticsLabel,
      child: ColoredBox(
        color: CupertinoColors.black,
        child: Column(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.semanticsLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: CupertinoColors.white),
                    ),
                  ),
                  CupertinoButton(
                    key: const ValueKey('vnc-clipboard-toggle'),
                    minimumSize: const Size(48, 48),
                    onPressed:
                        controller.clipboardSupported &&
                            controller.phase == VncSurfacePhase.active
                        ? () => controller.setClipboardEnabled(
                            !controller.clipboardEnabled,
                          )
                        : null,
                    child: Icon(
                      controller.clipboardEnabled
                          ? CupertinoIcons.doc_on_clipboard_fill
                          : CupertinoIcons.doc_on_clipboard,
                      semanticLabel: widget.clipboardLabel,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewport = constraints.biggest;
                  return Focus(
                    autofocus: true,
                    onKeyEvent: (_, event) {
                      final code = event.physicalKey.usbHidUsage & 0xffff;
                      if (code == 0 || event is KeyRepeatEvent) {
                        return KeyEventResult.ignored;
                      }
                      unawaited(controller.key(code, event is KeyDownEvent));
                      return KeyEventResult.handled;
                    },
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (event) => unawaited(
                        controller.pointer(
                          event.localPosition,
                          viewport,
                          event.buttons,
                        ),
                      ),
                      onPointerMove: (event) => unawaited(
                        controller.pointer(
                          event.localPosition,
                          viewport,
                          event.buttons,
                        ),
                      ),
                      onPointerUp: (event) => unawaited(
                        controller.pointer(event.localPosition, viewport, 0),
                      ),
                      child: CustomPaint(
                        key: const ValueKey('vnc-framebuffer'),
                        painter: _VncFramePainter(controller.renderedFrame),
                        size: Size.infinite,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_changed);
    unawaited(widget.controller.retire());
    super.dispose();
  }
}

class _VncFramePainter extends CustomPainter {
  const _VncFramePainter(this.frame);
  final VncDecodedFrame? frame;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(CupertinoColors.black, BlendMode.src);
    final value = frame;
    if (value == null) return;
    final destination = VncViewportTransform.fit(value.size, size).destination;
    canvas.drawImageRect(
      value.image,
      Rect.fromLTWH(0, 0, value.size.width, value.size.height),
      destination,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_VncFramePainter oldDelegate) =>
      oldDelegate.frame != frame;
}
