import 'dart:typed_data';

import 'camera_clip_source_stub.dart'
    if (dart.library.io) 'camera_clip_source_io.dart'
    if (dart.library.js_interop) 'camera_clip_source_web.dart'
    as platform;

abstract interface class CameraClipSource {
  String get uri;
  Future<void> dispose();
}

Future<CameraClipSource> createCameraClipSource(Uint8List bytes) =>
    platform.create(bytes);
