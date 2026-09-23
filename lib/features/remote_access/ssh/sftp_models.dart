import 'dart:typed_data';

const sftpMaxEntries = 200;
const sftpMaxTransferBytes = 64 * 1024 * 1024;
const sftpMaxPathBytes = 4096;
const sftpMaxNameBytes = 255;

class SftpFailure implements Exception {
  const SftpFailure(this.code);
  final String code;

  @override
  String toString() => 'SftpFailure($code)';
}

enum SftpEntryKind { directory, file }

class SftpEntry {
  const SftpEntry.directory(this.name, this.path)
    : kind = SftpEntryKind.directory,
      size = null,
      modifiedAt = null;

  const SftpEntry.file(this.name, this.path, {this.size, this.modifiedAt})
    : kind = SftpEntryKind.file;

  final String name;
  final String path;
  final SftpEntryKind kind;
  final int? size;
  final DateTime? modifiedAt;

  bool get isDirectory => kind == SftpEntryKind.directory;
}

class SftpListing {
  const SftpListing(this.entries, {required this.truncated});
  final List<SftpEntry> entries;
  final bool truncated;
}

class SftpUpload {
  SftpUpload(this.name, List<int> bytes) : bytes = Uint8List.fromList(bytes);
  SftpUpload.adoptOwned(this.name, this.bytes);
  final String name;
  final Uint8List bytes;

  void clear() => bytes.fillRange(0, bytes.length, 0);
}

int? _strictUtf8Length(String value) {
  var length = 0;
  final codeUnits = value.codeUnits;
  for (var index = 0; index < codeUnits.length; index++) {
    final unit = codeUnits[index];
    if (unit <= 0x7f) {
      length += 1;
    } else if (unit <= 0x7ff) {
      length += 2;
    } else if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= codeUnits.length) return null;
      final low = codeUnits[index];
      if (low < 0xdc00 || low > 0xdfff) return null;
      length += 4;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return null;
    } else {
      length += 3;
    }
  }
  return length;
}

String normalizeSftpPath(String value, {String base = '/'}) {
  void validate(String candidate) {
    final byteLength = _strictUtf8Length(candidate);
    if (candidate.contains('\\') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(candidate) ||
        byteLength == null ||
        byteLength > sftpMaxPathBytes) {
      throw const SftpFailure('invalid_path');
    }
  }

  validate(value);
  validate(base);
  final initial = value.startsWith('/')
      ? value
      : '${normalizeSftpPath(base)}/$value';
  final parts = <String>[];
  for (final segment in initial.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(segment);
  }
  final result = '/${parts.join('/')}';
  validate(result);
  return result;
}

String joinSftpPath(String directory, String name) {
  final byteLength = _strictUtf8Length(name);
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.contains('/') ||
      name.contains('\\') ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
      byteLength == null ||
      byteLength > sftpMaxNameBytes) {
    throw const SftpFailure('invalid_name');
  }
  return normalizeSftpPath(name, base: directory);
}

String sftpParentPath(String path) {
  final normalized = normalizeSftpPath(path);
  if (normalized == '/') return '/';
  final index = normalized.lastIndexOf('/');
  return index <= 0 ? '/' : normalized.substring(0, index);
}
