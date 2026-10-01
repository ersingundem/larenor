import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/rdp/rdp_display_geometry.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';

void main() {
  test('fit contains pixels and rejects letterbox input', () {
    final geometry = RdpDisplayGeometry.calculate(
      mode: RdpDisplayMode.fitWindow,
      frameSize: const Size(1600, 900),
      viewportSize: const Size(1000, 1000),
      devicePixelRatio: 1,
    );
    expect(geometry.destination, const Rect.fromLTWH(0, 218.75, 1000, 562.5));
    expect(geometry.normalize(const Offset(500, 500)), const Offset(.5, .5));
    expect(geometry.normalize(const Offset(500, 100)), isNull);
  });

  test('fill covers viewport and maps through the cropped source', () {
    final geometry = RdpDisplayGeometry.calculate(
      mode: RdpDisplayMode.fillWindow,
      frameSize: const Size(1600, 900),
      viewportSize: const Size(1000, 1000),
      devicePixelRatio: 1,
    );
    expect(
      geometry.destination,
      const Rect.fromLTWH(-388.8888888888889, 0, 1777.7777777777778, 1000),
    );
    expect(geometry.normalize(const Offset(500, 500)), const Offset(.5, .5));
    expect(geometry.normalize(const Offset(0, 500))!.dx, closeTo(.21875, 1e-9));
    expect(
      geometry.normalize(const Offset(999.999, 500))!.dx,
      closeTo(.78125, 1e-5),
    );
  });

  test('native stays one-to-one, clamps pan and maps visible pixels', () {
    var geometry = RdpDisplayGeometry.calculate(
      mode: RdpDisplayMode.native,
      frameSize: const Size(1600, 900),
      viewportSize: const Size(1000, 600),
      devicePixelRatio: 1,
      nativePan: const Offset(900, 500),
    );
    expect(geometry.nativePan, const Offset(600, 300));
    expect(geometry.destination, const Rect.fromLTWH(-600, -300, 1600, 900));
    expect(geometry.normalize(Offset.zero), const Offset(.375, 1 / 3));
    final farEdge = geometry.normalize(const Offset(999.999, 599.999))!;
    expect(farEdge.dx, closeTo(1, 1e-5));
    expect(farEdge.dy, closeTo(1, 1e-5));

    geometry = RdpDisplayGeometry.calculate(
      mode: RdpDisplayMode.native,
      frameSize: const Size(400, 300),
      viewportSize: const Size(1000, 600),
      devicePixelRatio: 1,
      nativePan: const Offset(20, 30),
    );
    expect(geometry.nativePan, Offset.zero);
    expect(geometry.destination, const Rect.fromLTWH(300, 150, 400, 300));
    expect(geometry.normalize(const Offset(200, 200)), isNull);
  });

  test('native drag moves the viewport without escaping the frame', () {
    final geometry = RdpDisplayGeometry.calculate(
      mode: RdpDisplayMode.native,
      frameSize: const Size(1600, 900),
      viewportSize: const Size(1000, 600),
      devicePixelRatio: 1,
      nativePan: const Offset(100, 100),
    );
    expect(geometry.panAfterDrag(const Offset(-80, 30)), const Offset(180, 70));
    expect(
      geometry.panAfterDrag(const Offset(1000, -1000)),
      const Offset(0, 300),
    );
  });

  test(
    'native maps remote physical pixels to logical pixels at DPR 2 and 3',
    () {
      final cropped = RdpDisplayGeometry.calculate(
        mode: RdpDisplayMode.native,
        frameSize: const Size(3000, 1800),
        viewportSize: const Size(1000, 600),
        devicePixelRatio: 2,
        nativePan: const Offset(900, 500),
      );
      expect(cropped.destination, const Rect.fromLTWH(-500, -300, 1500, 900));
      expect(cropped.nativePan, const Offset(500, 300));
      expect(cropped.normalize(Offset.zero), const Offset(1 / 3, 1 / 3));

      final letterboxed = RdpDisplayGeometry.calculate(
        mode: RdpDisplayMode.native,
        frameSize: const Size(1200, 900),
        viewportSize: const Size(1000, 600),
        devicePixelRatio: 3,
      );
      expect(letterboxed.destination, const Rect.fromLTWH(300, 150, 400, 300));
      expect(letterboxed.normalize(const Offset(299, 300)), isNull);
      expect(
        letterboxed.normalize(const Offset(500, 300)),
        const Offset(.5, .5),
      );
    },
  );

  test('invalid geometry fails closed', () {
    expect(
      () => RdpDisplayGeometry.calculate(
        mode: RdpDisplayMode.fitWindow,
        frameSize: Size.zero,
        viewportSize: const Size(100, 100),
        devicePixelRatio: 1,
      ),
      throwsArgumentError,
    );
    expect(
      RdpDisplayGeometry.clampNativePan(
        contentSize: const Size(100, 100),
        viewportSize: const Size(50, 50),
        pan: const Offset(double.nan, 4),
      ),
      Offset.zero,
    );
    expect(
      () => RdpDisplayGeometry.calculate(
        mode: RdpDisplayMode.native,
        frameSize: const Size(100, 100),
        viewportSize: const Size(100, 100),
        devicePixelRatio: 0,
      ),
      throwsArgumentError,
    );
  });
}
