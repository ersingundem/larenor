import 'dart:ui';

import 'rdp_models.dart';

/// Pure display geometry for the Flutter-owned RDP framebuffer surface.
///
/// The native channel always receives normalized remote coordinates. This
/// class keeps scaling, cropping, letterboxing and native-pixel panning in one
/// place so rendering and input use the same transform.
class RdpDisplayGeometry {
  const RdpDisplayGeometry._({
    required this.mode,
    required this.frameSize,
    required this.viewportSize,
    required this.devicePixelRatio,
    required this.destination,
    required this.nativePan,
  });

  factory RdpDisplayGeometry.calculate({
    required RdpDisplayMode mode,
    required Size frameSize,
    required Size viewportSize,
    required double devicePixelRatio,
    Offset nativePan = Offset.zero,
  }) {
    if (!_validSize(frameSize) ||
        !_validSize(viewportSize) ||
        !devicePixelRatio.isFinite ||
        devicePixelRatio <= 0) {
      throw ArgumentError('display geometry requires finite positive sizes');
    }
    if (mode == RdpDisplayMode.native) {
      final contentSize = Size(
        frameSize.width / devicePixelRatio,
        frameSize.height / devicePixelRatio,
      );
      final pan = clampNativePan(
        contentSize: contentSize,
        viewportSize: viewportSize,
        pan: nativePan,
      );
      final left = contentSize.width <= viewportSize.width
          ? (viewportSize.width - contentSize.width) / 2
          : -pan.dx;
      final top = contentSize.height <= viewportSize.height
          ? (viewportSize.height - contentSize.height) / 2
          : -pan.dy;
      return RdpDisplayGeometry._(
        mode: mode,
        frameSize: frameSize,
        viewportSize: viewportSize,
        devicePixelRatio: devicePixelRatio,
        destination: Rect.fromLTWH(
          left,
          top,
          contentSize.width,
          contentSize.height,
        ),
        nativePan: pan,
      );
    }

    final widthScale = viewportSize.width / frameSize.width;
    final heightScale = viewportSize.height / frameSize.height;
    final scale = mode == RdpDisplayMode.fitWindow
        ? widthScale < heightScale
              ? widthScale
              : heightScale
        : widthScale > heightScale
        ? widthScale
        : heightScale;
    final rendered = Size(frameSize.width * scale, frameSize.height * scale);
    return RdpDisplayGeometry._(
      mode: mode,
      frameSize: frameSize,
      viewportSize: viewportSize,
      devicePixelRatio: devicePixelRatio,
      destination: Rect.fromLTWH(
        (viewportSize.width - rendered.width) / 2,
        (viewportSize.height - rendered.height) / 2,
        rendered.width,
        rendered.height,
      ),
      nativePan: Offset.zero,
    );
  }

  final RdpDisplayMode mode;
  final Size frameSize;
  final Size viewportSize;
  final double devicePixelRatio;
  final Rect destination;
  final Offset nativePan;

  static bool _validSize(Size value) =>
      value.width.isFinite &&
      value.height.isFinite &&
      value.width > 0 &&
      value.height > 0;

  static Offset clampNativePan({
    required Size contentSize,
    required Size viewportSize,
    required Offset pan,
  }) {
    if (!_validSize(contentSize) ||
        !_validSize(viewportSize) ||
        !pan.dx.isFinite ||
        !pan.dy.isFinite) {
      return Offset.zero;
    }
    return Offset(
      pan.dx.clamp(
        0,
        (contentSize.width - viewportSize.width).clamp(0, double.infinity),
      ),
      pan.dy.clamp(
        0,
        (contentSize.height - viewportSize.height).clamp(0, double.infinity),
      ),
    );
  }

  Offset panAfterDrag(Offset delta) => clampNativePan(
    contentSize: destination.size,
    viewportSize: viewportSize,
    pan: nativePan - delta,
  );

  /// Maps one viewport point into normalized remote coordinates.
  ///
  /// Letterbox/pillarbox points and points outside the visible native image
  /// return null. Fill mode naturally includes the crop offset because its
  /// destination rectangle extends beyond the viewport.
  Offset? normalize(Offset viewportPoint) {
    final viewport = Offset.zero & viewportSize;
    if (!viewport.contains(viewportPoint) ||
        !destination.contains(viewportPoint)) {
      return null;
    }
    return Offset(
      ((viewportPoint.dx - destination.left) / destination.width).clamp(0, 1),
      ((viewportPoint.dy - destination.top) / destination.height).clamp(0, 1),
    );
  }
}
