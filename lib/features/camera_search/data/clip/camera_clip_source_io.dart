import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'camera_clip_source.dart';

Future<Directory>? _root;
Future<Directory> _privateRoot() => _root ??= (() async {
  final root = Directory(
    '${(await getTemporaryDirectory()).path}/larenor-camera-clips',
  );
  await root.create(recursive: true);
  // After a process crash only this app-owned namespace is cleaned.
  await for (final entry in root.list(followLinks: false)) {
    if (entry is Directory &&
        entry.path.split(Platform.pathSeparator).last.startsWith('clip-')) {
      await entry.delete(recursive: true);
    }
  }
  return root;
})();

Future<CameraClipSource> create(Uint8List bytes) async {
  final directory = await (await _privateRoot()).createTemp('clip-');
  try {
    final file = File('${directory.path}/video.mp4');
    await file.writeAsBytes(bytes, flush: true);
    return _Source(directory, file.uri.toString());
  } catch (_) {
    await directory.delete(recursive: true);
    rethrow;
  }
}

final class _Source implements CameraClipSource {
  _Source(this.directory, this.uri);
  final Directory directory;
  @override
  final String uri;
  bool _disposed = false;
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
