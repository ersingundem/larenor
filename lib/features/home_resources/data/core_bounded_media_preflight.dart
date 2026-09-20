import 'dart:convert';

import 'core_bounded_download_api.dart';

/// A closed, local content policy applied after wire integrity succeeds and
/// before Android's Storage Access Framework receives any bytes.
final class CoreBoundedMediaPreflight {
  const CoreBoundedMediaPreflight._();

  static void verify(String contentType, List<int> bytes) {
    if (bytes.isEmpty || bytes.length > CoreBoundedDownloadApi.maxBlobBytes) {
      _reject();
    }
    final type = _mediaType(contentType);
    final valid = switch (type) {
      'text/plain' => _text(bytes),
      'application/json' => _json(bytes),
      'application/pdf' => _starts(bytes, const [0x25, 0x50, 0x44, 0x46, 0x2d]),
      'image/png' => _starts(bytes, const [
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]),
      'image/jpeg' =>
        _starts(bytes, const [0xff, 0xd8, 0xff]) &&
            bytes.length >= 5 &&
            bytes[bytes.length - 2] == 0xff &&
            bytes.last == 0xd9,
      'image/webp' => _ascii(bytes, 0, 'RIFF') && _ascii(bytes, 8, 'WEBP'),
      'audio/mpeg' =>
        _ascii(bytes, 0, 'ID3') ||
            bytes.length >= 2 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0,
      'audio/flac' => _ascii(bytes, 0, 'fLaC'),
      'audio/wav' => _ascii(bytes, 0, 'RIFF') && _ascii(bytes, 8, 'WAVE'),
      'audio/ogg' => _ascii(bytes, 0, 'OggS'),
      'video/mp4' => _ascii(bytes, 4, 'ftyp'),
      'video/webm' => _starts(bytes, const [0x1a, 0x45, 0xdf, 0xa3]),
      _ => false,
    };
    if (!valid) _reject();
  }

  static String _mediaType(String raw) {
    if (raw.isEmpty || raw.length > 128) _reject();
    final parts = raw
        .split(';')
        .map((part) => part.trim().toLowerCase())
        .toList();
    final base = parts.first;
    final textual = base == 'text/plain' || base == 'application/json';
    if (parts.length > 2 ||
        parts.length == 2 && (!textual || parts[1] != 'charset=utf-8')) {
      _reject();
    }
    if (!textual && parts.length != 1) _reject();
    return base;
  }

  static bool _text(List<int> bytes) {
    try {
      final value = utf8.decode(bytes, allowMalformed: false);
      return !value.contains('\u0000');
    } on FormatException {
      return false;
    }
  }

  static bool _json(List<int> bytes) {
    try {
      jsonDecode(utf8.decode(bytes, allowMalformed: false));
      return true;
    } on FormatException {
      return false;
    }
  }

  static bool _starts(List<int> bytes, List<int> expected) {
    if (bytes.length < expected.length) return false;
    for (var index = 0; index < expected.length; index++) {
      if (bytes[index] != expected[index]) return false;
    }
    return true;
  }

  static bool _ascii(List<int> bytes, int offset, String value) {
    final expected = ascii.encode(value);
    if (offset < 0 || bytes.length < offset + expected.length) return false;
    for (var index = 0; index < expected.length; index++) {
      if (bytes[offset + index] != expected[index]) return false;
    }
    return true;
  }

  static Never _reject() =>
      throw const CoreBoundedDownloadException('file_access_failed');
}
