import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'camera_clip_source.dart';

Future<CameraClipSource> create(Uint8List bytes) async => _Source(
  web.URL.createObjectURL(
    web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: 'video/mp4')),
  ),
);

final class _Source implements CameraClipSource {
  _Source(this.uri);
  @override
  final String uri;
  bool _disposed = false;
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    web.URL.revokeObjectURL(uri);
  }
}
