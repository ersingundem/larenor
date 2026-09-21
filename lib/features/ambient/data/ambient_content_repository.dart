import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/configuration_writes.dart';
import '../domain/ambient_content.dart';
import 'ambient_repository.dart';

abstract interface class AmbientContentStore {
  Future<Uint8List> readLocal(AmbientContent item);
}

abstract interface class AmbientContentRepositoryApi
    implements AmbientContentStore {
  Future<List<AmbientContent>> list();
  Future<void> importLocal(
    AmbientContentKind kind,
    Stream<List<int>> source, {
    required bool Function() isCurrent,
  });
  Future<void> addWeb(String url, {required bool Function() isCurrent});
  Future<void> replaceOrder(
    List<AmbientContent> values, {
    required List<AmbientContent> expected,
    required bool Function() isCurrent,
  });
}

final class AmbientContentRepository implements AmbientContentRepositoryApi {
  AmbientContentRepository({Future<Directory> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  static const maxItems = 24;
  static const maxPdfBytes = 32 * 1024 * 1024;
  static const maxVideoBytes = 96 * 1024 * 1024;
  static const maxLibraryBytes = 256 * 1024 * 1024;
  final Future<Directory> Function() _directory;

  static Future<Directory> _defaultDirectory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/ambient_content_v1',
  );

  Future<Directory> _root({bool create = false}) async {
    final root = await _directory();
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type == FileSystemEntityType.notFound && create) {
      await root.create(recursive: true);
    } else if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.notFound) {
      throw const AmbientContentException();
    }
    return root;
  }

  @override
  Future<List<AmbientContent>> list() async {
    final root = await _root();
    final manifest = File('${root.path}/library.json');
    if (await FileSystemEntity.type(manifest.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return const [];
    }
    try {
      final bytes = await AmbientRepository.boundedBytes(
        manifest.openRead(),
        32 * 1024,
      );
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map<String, dynamic> ||
          raw.length != 2 ||
          raw['version'] != 1 ||
          raw['items'] is! List) {
        throw const AmbientContentException();
      }
      final values = (raw['items'] as List)
          .map(AmbientContent.fromJson)
          .toList(growable: false);
      if (values.length > maxItems ||
          values.map((value) => value.id).toSet().length != values.length ||
          values.fold<int>(0, (sum, value) => sum + value.sizeBytes) >
              maxLibraryBytes) {
        throw const AmbientContentException();
      }
      return List.unmodifiable(values);
    } catch (_) {
      throw const AmbientContentException();
    }
  }

  @override
  Future<void> importLocal(
    AmbientContentKind kind,
    Stream<List<int>> source, {
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    if (!isCurrent()) return;
    if (kind == AmbientContentKind.web) throw const AmbientContentException();
    final limit = kind == AmbientContentKind.pdf ? maxPdfBytes : maxVideoBytes;
    final bytes = await AmbientRepository.boundedBytes(source, limit);
    if (!isCurrent()) return;
    _validateLocal(kind, bytes);
    final items = await list();
    if (items.length >= maxItems) {
      throw const AmbientContentException(limit: true);
    }
    final id = sha256.convert(bytes).toString();
    if (items.any((item) => item.id == id)) return;
    if (items.fold<int>(0, (sum, item) => sum + item.sizeBytes) + bytes.length >
        maxLibraryBytes) {
      throw const AmbientContentException(limit: true);
    }
    final item = AmbientContent.local(
      id: id,
      kind: kind,
      sizeBytes: bytes.length,
    );
    final root = await _root(create: true);
    final destination = File('${root.path}/$id.${item.extension}');
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const AmbientContentException();
    }
    try {
      await destination.writeAsBytes(bytes, flush: true);
      if (!isCurrent()) return;
      await _save(root, [...items, item], isCurrent);
    } finally {
      final current = await list();
      if (!current.contains(item) && await destination.exists()) {
        await destination.delete();
      }
    }
  });

  @override
  Future<void> addWeb(String url, {required bool Function() isCurrent}) =>
      ConfigurationWrites.run(() async {
        if (!isCurrent()) return;
        final encoded = utf8.encode(url);
        final item = AmbientContent.web(
          id: sha256.convert(encoded).toString(),
          url: url,
        );
        final items = await list();
        if (items.any((value) => value.id == item.id)) return;
        if (items.length >= maxItems) {
          throw const AmbientContentException(limit: true);
        }
        await _save(await _root(create: true), [...items, item], isCurrent);
      });

  @override
  Future<void> replaceOrder(
    List<AmbientContent> values, {
    required List<AmbientContent> expected,
    required bool Function() isCurrent,
  }) {
    final selected = List<AmbientContent>.unmodifiable(values);
    final baseline = List<AmbientContent>.unmodifiable(expected);
    return ConfigurationWrites.run(() async {
      if (!isCurrent()) return;
      final current = await list();
      if (!_same(current, baseline) ||
          selected.length > current.length ||
          selected.toSet().length != selected.length ||
          selected.any((item) => !current.contains(item))) {
        throw const AmbientContentException();
      }
      final root = await _root(create: true);
      if (await _save(root, selected, isCurrent)) {
        await _collectOrphans(root, selected);
      }
    });
  }

  @override
  Future<Uint8List> readLocal(AmbientContent item) async {
    try {
      if (item.kind == AmbientContentKind.web) {
        throw const AmbientContentException();
      }
      final current = await list();
      if (!current.contains(item)) throw const AmbientContentException();
      final root = await _root();
      final file = File('${root.path}/${item.id}.${item.extension}');
      final limit = item.kind == AmbientContentKind.pdf
          ? maxPdfBytes
          : maxVideoBytes;
      final bytes = await AmbientRepository.boundedBytes(
        file.openRead(),
        limit,
      );
      if (bytes.length != item.sizeBytes ||
          sha256.convert(bytes).toString() != item.id) {
        throw const AmbientContentException();
      }
      _validateLocal(item.kind, bytes);
      return bytes;
    } catch (_) {
      throw const AmbientContentException();
    }
  }

  static void _validateLocal(AmbientContentKind kind, Uint8List bytes) {
    final pdf =
        bytes.length >= 10 &&
        utf8.decode(bytes.take(5).toList(), allowMalformed: true) == '%PDF-' &&
        utf8
            .decode(
              bytes.sublist(bytes.length > 1024 ? bytes.length - 1024 : 0),
              allowMalformed: true,
            )
            .trimRight()
            .endsWith('%%EOF');
    final video =
        bytes.length >= 12 &&
        utf8.decode(bytes.sublist(4, 8), allowMalformed: true) == 'ftyp' &&
        const {
          'isom',
          'iso2',
          'mp41',
          'mp42',
          'avc1',
          'M4V ',
        }.contains(utf8.decode(bytes.sublist(8, 12), allowMalformed: true));
    if ((kind == AmbientContentKind.pdf && !pdf) ||
        (kind == AmbientContentKind.video && !video)) {
      throw const AmbientContentException();
    }
  }

  Future<bool> _save(
    Directory root,
    List<AmbientContent> items,
    bool Function() isCurrent,
  ) async {
    final staging = File('${root.path}/library.tmp');
    final type = await FileSystemEntity.type(staging.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw const AmbientContentException();
    }
    await staging.writeAsString(
      jsonEncode({
        'version': 1,
        'items': items.map((e) => e.toJson()).toList(),
      }),
      flush: true,
    );
    if (!isCurrent()) {
      await staging.delete();
      return false;
    }
    await staging.rename('${root.path}/library.json');
    return true;
  }

  Future<void> _collectOrphans(
    Directory root,
    List<AmbientContent> items,
  ) async {
    final names = {
      for (final item in items)
        if (item.kind != AmbientContentKind.web) '${item.id}.${item.extension}',
    };
    await for (final entry in root.list(followLinks: false)) {
      final name = entry.uri.pathSegments.last;
      if (entry is File &&
          RegExp(r'^[a-f0-9]{64}\.(pdf|mp4)$').hasMatch(name) &&
          !names.contains(name)) {
        await entry.delete();
      }
    }
  }

  static bool _same(List<AmbientContent> a, List<AmbientContent> b) =>
      a.length == b.length &&
      List.generate(a.length, (index) => a[index] == b[index]).every((v) => v);
}

final class AmbientContentFileAccess {
  Future<Stream<List<int>>?> pick(AmbientContentKind kind) async {
    if (kind == AmbientContentKind.web) throw const AmbientContentException();
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: [kind == AmbientContentKind.pdf ? 'pdf' : 'mp4'],
    );
    if (file == null) return null;
    final length = await file.length();
    final limit = kind == AmbientContentKind.pdf
        ? AmbientContentRepository.maxPdfBytes
        : AmbientContentRepository.maxVideoBytes;
    if (length == null || length < 1 || length > limit) {
      throw const AmbientContentException(limit: true);
    }
    return file.readAsByteStream();
  }
}
