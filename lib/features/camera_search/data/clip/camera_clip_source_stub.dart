import 'dart:typed_data';

import 'camera_clip_source.dart';

Future<CameraClipSource> create(Uint8List bytes) =>
    Future.error(UnsupportedError('camera_clip_platform'));
