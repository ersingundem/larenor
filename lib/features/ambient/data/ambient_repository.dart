import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/configuration_writes.dart';
import '../domain/ambient_settings.dart';

typedef AmbientImageNormalizer = Future<Uint8List> Function(Uint8List bytes);

/// Only explicit system-picker selections enter this store. No directory scan
/// outside the private, dedicated folder and no URLs/EXIF/filenames are stored.
class AmbientRepository {
  AmbientRepository({
    Future<Directory> Function()? directory,
    AmbientImageNormalizer? normalize,
  }) : _directory = directory ?? _defaultDirectory,
       _normalize = normalize ?? normalizePhoto;

  static const maxPhotos = 24;
  static const maxSourceBytes = 12 * 1024 * 1024;
  static const maxPhotoBytes = 8 * 1024 * 1024;
  static const maxLibraryBytes = 96 * 1024 * 1024;
  static final _validId = RegExp(r'^[a-f0-9]{64}$');
  final Future<Directory> Function() _directory;
  final AmbientImageNormalizer _normalize;

  static Future<Directory> _defaultDirectory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/ambient_photos_v1',
  );

  Future<Directory> _root({bool create = false}) async {
    final dir = await _directory();
    final type = await FileSystemEntity.type(dir.path, followLinks: false);
    if (type == FileSystemEntityType.notFound && create) {
      await dir.create(recursive: true);
    } else if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.notFound) {
      throw const AmbientException();
    }
    return dir;
  }

  Future<List<String>> list() async {
    final root = await _root();
    final file = File('${root.path}/library.json');
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return const [];
    }
    final bytes = await _read(file, 4096);
    try {
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map ||
          data.length != 2 ||
          data['version'] is! int ||
          data['version'] != 1 ||
          data['photos'] is! List) {
        throw const AmbientException();
      }
      final photos = data['photos'] as List;
      if (photos.length > maxPhotos ||
          photos.any((v) => v is! String || !_validId.hasMatch(v)) ||
          photos.toSet().length != photos.length) {
        throw const AmbientException();
      }
      return List<String>.unmodifiable(photos);
    } catch (_) {
      throw const AmbientException();
    }
  }

  Future<Uint8List> readPhoto(String id) async {
    if (!_validId.hasMatch(id)) throw const AmbientException();
    // A stale UI cannot read an image removed from the explicit library.
    if (!(await list()).contains(id)) throw const AmbientException();
    final root = await _root();
    final bytes = await _read(File('${root.path}/$id.png'), maxPhotoBytes);
    if (sha256.convert(bytes).toString() != id) {
      throw const AmbientException();
    }
    return bytes;
  }

  Future<void> importPhoto(
    Uint8List source, {
    required bool Function() isCurrent,
  }) {
    if (!isCurrent()) return Future.value();
    if (source.isEmpty || source.length > maxSourceBytes) {
      return Future.error(const AmbientException(limit: true));
    }
    final selected = Uint8List.fromList(source);
    return ConfigurationWrites.run(() async {
      if (!isCurrent()) return;
      final photos = await list();
      if (photos.length >= maxPhotos) throw const AmbientException(limit: true);
      if (!isCurrent()) return;
      final normalized = await _normalize(selected);
      if (!isCurrent()) return;
      if (normalized.isEmpty || normalized.length > maxPhotoBytes) {
        throw const AmbientException(limit: true);
      }
      final id = sha256.convert(normalized).toString();
      if (photos.contains(id)) return;
      final root = await _root(create: true);
      await _collectOrphans(root, photos);
      var total = normalized.length;
      for (final existing in photos) {
        final file = File('${root.path}/$existing.png');
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (type == FileSystemEntityType.notFound) continue;
        if (type != FileSystemEntityType.file) throw const AmbientException();
        total += await file.length();
      }
      if (total > maxLibraryBytes) throw const AmbientException(limit: true);
      if (!isCurrent()) return;
      final image = File('${root.path}/$id.png');
      final imageType = await FileSystemEntity.type(
        image.path,
        followLinks: false,
      );
      if (imageType != FileSystemEntityType.notFound) {
        throw const AmbientException();
      }
      try {
        await image.writeAsBytes(normalized, flush: true);
        if (!isCurrent()) return;
        await _save(root, [...photos, id], isCurrent);
      } finally {
        // A crash may leave an unreferenced copy; the next mutation removes only
        // those managed copies. A failed manifest write never hides old photos.
        if (!(await list()).contains(id) && await image.exists()) {
          await image.delete();
        }
      }
    });
  }

  Future<void> replaceOrder(
    List<String> ids, {
    required List<String> expected,
    required bool Function() isCurrent,
  }) {
    final selectedIds = List<String>.unmodifiable(ids);
    final expectedIds = List<String>.unmodifiable(expected);
    return ConfigurationWrites.run(() async {
      if (!isCurrent()) return;
      final photos = await list();
      if (expectedIds.join() != photos.join() ||
          selectedIds.length > photos.length ||
          selectedIds.toSet().length != selectedIds.length ||
          selectedIds.any((id) => !photos.contains(id))) {
        throw const AmbientException();
      }
      final root = await _root(create: true);
      if (!isCurrent()) return;
      if (await _save(root, selectedIds, isCurrent)) {
        await _collectOrphans(root, selectedIds);
      }
    });
  }

  Future<bool> _save(
    Directory root,
    List<String> ids,
    bool Function() isCurrent,
  ) async {
    final staging = File('${root.path}/library.tmp');
    final type = await FileSystemEntity.type(staging.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw const AmbientException();
    }
    await staging.writeAsString(
      jsonEncode({'version': 1, 'photos': ids}),
      flush: true,
    );
    if (!isCurrent()) {
      await staging.delete();
      return false;
    }
    await staging.rename('${root.path}/library.json');
    return true;
  }

  Future<void> _collectOrphans(Directory root, List<String> ids) async {
    await for (final entry in root.list(followLinks: false)) {
      final name = entry.uri.pathSegments.last;
      if (entry is File &&
          name.endsWith('.png') &&
          _validId.hasMatch(name.substring(0, name.length - 4)) &&
          !ids.contains(name.substring(0, name.length - 4))) {
        await entry.delete();
      }
    }
  }

  static Future<Uint8List> _read(File file, int maxBytes) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const AmbientException();
    }
    if (await file.length() > maxBytes) {
      throw const AmbientException(limit: true);
    }
    return boundedBytes(file.openRead(), maxBytes);
  }

  static Future<Uint8List> boundedBytes(
    Stream<List<int>> chunks,
    int maxBytes,
  ) async {
    final bytes = BytesBuilder(copy: false);
    final iterator = StreamIterator(chunks);
    final expired = Completer<bool>();
    final deadline = Timer(const Duration(seconds: 15), () {
      expired.completeError(const AmbientException());
    });
    try {
      while (true) {
        if (!await Future.any([iterator.moveNext(), expired.future])) break;
        final chunk = iterator.current;
        if (bytes.length + chunk.length > maxBytes) {
          throw const AmbientException(limit: true);
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } finally {
      deadline.cancel();
      try {
        await iterator.cancel().timeout(const Duration(seconds: 1));
      } catch (_) {
        // A provider's stuck cleanup must not keep the picker UI busy forever.
      }
    }
  }

  static Future<Uint8List> normalizePhoto(Uint8List bytes) async {
    final png =
        bytes.length >= 8 &&
        bytes[0] == 137 &&
        bytes[1] == 80 &&
        bytes[2] == 78 &&
        bytes[3] == 71;
    final jpeg =
        bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255;
    if ((!png && !jpeg) || bytes.length > maxSourceBytes) {
      throw const AmbientException();
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width < 1 ||
          descriptor.height < 1 ||
          descriptor.width * descriptor.height > 24000000) {
        throw const AmbientException(limit: true);
      }
      final scale = math.min(
        1.0,
        1920 / math.max(descriptor.width, descriptor.height),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      if (codec.frameCount != 1) throw const AmbientException();
      image = (await codec.getNextFrame()).image;
      // Re-encoding drops source metadata, including location and camera tags.
      final output = await image.toByteData(format: ui.ImageByteFormat.png);
      if (output == null || output.lengthInBytes > maxPhotoBytes) {
        throw const AmbientException(limit: true);
      }
      return output.buffer.asUint8List(
        output.offsetInBytes,
        output.lengthInBytes,
      );
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}

class AmbientFileAccess {
  Future<Uint8List?> pickPhoto() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png'],
    );
    if (file == null) return null;
    if (await file.length() > AmbientRepository.maxSourceBytes) {
      throw const AmbientException(limit: true);
    }
    return AmbientRepository.boundedBytes(
      file.readAsByteStream(),
      AmbientRepository.maxSourceBytes,
    );
  }
}
