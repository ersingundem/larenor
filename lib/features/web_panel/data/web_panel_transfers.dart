import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../domain/web_panel_policy.dart';

const webPanelMaxTransferBytes = 25 * 1024 * 1024;

enum WebPanelTransferStatus {
  idle,
  uploadArmed,
  downloadArmed,
  working,
  completed,
  denied,
  failed,
}

abstract interface class WebPanelTransferAccess {
  Future<List<String>> pickUpload(FileSelectorParams request);

  Future<bool> download(
    Uri uri,
    WebPanelPolicy policy,
    bool Function() isCurrent,
  );
}

typedef WebPanelPickFiles = Future<List<PlatformFile>> Function({
  required bool allowMultiple,
  required List<String> allowedExtensions,
});
typedef WebPanelSaveFile = Future<Uri?> Function(
  String filename,
  String mimeType,
  Uint8List bytes,
);

final class LocalWebPanelTransferAccess implements WebPanelTransferAccess {
  LocalWebPanelTransferAccess({
    WebPanelPickFiles? pickFiles,
    WebPanelSaveFile? saveFile,
    http.Client Function()? client,
  }) : _pickFiles =
           pickFiles ??
           (({required allowMultiple, required allowedExtensions}) async {
             if (allowMultiple) {
               return FilePicker.pickFiles(
                 type: FileType.custom,
                 allowedExtensions: allowedExtensions,
               );
             }
             final value = await FilePicker.pickFile(
               type: FileType.custom,
               allowedExtensions: allowedExtensions,
             );
             return value == null ? const [] : [value];
           }),
       _saveFile =
           saveFile ??
           ((filename, mimeType, bytes) => FilePicker.saveFile(
             fileName: filename,
             mimeType: mimeType,
             bytes: bytes,
           )),
       _client = client ?? http.Client.new;

  final WebPanelPickFiles _pickFiles;
  final WebPanelSaveFile _saveFile;
  final http.Client Function() _client;

  static const _extensions = <String>{
    'jpg',
    'jpeg',
    'png',
    'webp',
    'pdf',
    'txt',
    'csv',
    'json',
  };

  static Set<String>? _acceptedExtensions(List<String> accepts) {
    if (accepts.isEmpty || accepts.every((value) => value.trim().isEmpty)) {
      return _extensions;
    }
    final result = <String>{};
    for (final raw in accepts) {
      for (final value in raw.toLowerCase().split(',')) {
        switch (value.trim()) {
          case 'image/*':
            result.addAll(const {'jpg', 'jpeg', 'png', 'webp'});
          case 'image/jpeg':
            result.addAll(const {'jpg', 'jpeg'});
          case 'image/png':
            result.add('png');
          case 'image/webp':
            result.add('webp');
          case 'application/pdf':
            result.add('pdf');
          case 'text/plain':
            result.add('txt');
          case 'text/csv':
            result.add('csv');
          case 'application/json':
            result.add('json');
          default:
            final extension = value.trim();
            if (RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension) &&
                _extensions.contains(extension.substring(1))) {
              result.add(extension.substring(1));
            }
        }
      }
    }
    return result.isEmpty ? null : result;
  }

  @override
  Future<List<String>> pickUpload(FileSelectorParams request) async {
    if (request.mode == FileSelectorMode.save || request.isCaptureEnabled) {
      return const [];
    }
    final extensions = _acceptedExtensions(request.acceptTypes);
    if (extensions == null) return const [];
    try {
      final selected = await _pickFiles(
        allowMultiple: request.mode == FileSelectorMode.openMultiple,
        allowedExtensions: extensions.toList(growable: false),
      );
      final files = selected;
      if (files.isEmpty || files.length > 4) return const [];
      final result = <String>[];
      for (final item in files) {
        final uri = item.uri;
        final path = item.path;
        final length = await item.length();
        if (!const {'file', 'content'}.contains(uri.scheme) ||
            length == null ||
            length < 1 ||
            length > webPanelMaxTransferBytes ||
            (path != null &&
                (FileSystemEntity.isLinkSync(path) ||
                    FileSystemEntity.typeSync(path) !=
                        FileSystemEntityType.file))) {
          return const [];
        }
        result.add(uri.toString());
      }
      return List.unmodifiable(result);
    } catch (_) {
      return const [];
    }
  }

  static (String, String)? _downloadType(String? header) {
    final mime = header?.split(';').first.trim().toLowerCase();
    return switch (mime) {
      'application/pdf' => ('application/pdf', 'pdf'),
      'image/jpeg' => ('image/jpeg', 'jpg'),
      'image/png' => ('image/png', 'png'),
      'image/webp' => ('image/webp', 'webp'),
      'text/plain' => ('text/plain', 'txt'),
      'text/csv' => ('text/csv', 'csv'),
      'application/json' => ('application/json', 'json'),
      _ => null,
    };
  }

  static bool _startsWith(Uint8List bytes, List<int> signature) {
    if (bytes.length < signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[index] != signature[index]) return false;
    }
    return true;
  }

  static int _uint32BigEndian(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static int _uint32LittleEndian(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static final _crc32Table = List<int>.unmodifiable(
    List<int>.generate(256, (value) {
      var crc = value;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1;
      }
      return crc;
    }),
  );

  static int _crc32(Uint8List bytes, int start, int end) {
    var crc = 0xffffffff;
    for (var index = start; index < end; index++) {
      crc = _crc32Table[(crc ^ bytes[index]) & 0xff] ^ (crc >> 8);
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }

  static bool _validPngHeader(Uint8List bytes, int start) {
    final width = _uint32BigEndian(bytes, start);
    final height = _uint32BigEndian(bytes, start + 4);
    if (width < 1 ||
        height < 1 ||
        width > 0x7fffffff ||
        height > 0x7fffffff ||
        bytes[start + 10] != 0 ||
        bytes[start + 11] != 0 ||
        bytes[start + 12] > 1) {
      return false;
    }
    final bitDepth = bytes[start + 8];
    return switch (bytes[start + 9]) {
      0 => const {1, 2, 4, 8, 16}.contains(bitDepth),
      2 || 4 || 6 => const {8, 16}.contains(bitDepth),
      3 => const {1, 2, 4, 8}.contains(bitDepth),
      _ => false,
    };
  }

  static bool _validPdf(Uint8List bytes) {
    if (bytes.length < 40 ||
        !_startsWith(bytes, const [0x25, 0x50, 0x44, 0x46, 0x2d])) {
      return false;
    }
    final text = latin1.decode(bytes, allowInvalid: true);
    if (!RegExp(r'^%PDF-(?:1\.[0-9]|2\.0)').hasMatch(text)) return false;
    final eof = text.lastIndexOf('%%EOF');
    if (eof < 0 || text.substring(eof + 5).trim().isNotEmpty) return false;
    final startXref = text.lastIndexOf('startxref', eof);
    if (startXref < 0 ||
        !RegExp(r'^startxref\s+[0-9]+\s*$')
            .hasMatch(text.substring(startXref, eof))) {
      return false;
    }
    final prefix = text.substring(0, startXref);
    return RegExp(r'\b[0-9]+\s+[0-9]+\s+obj\b').hasMatch(prefix) &&
        prefix.contains('endobj') &&
        (prefix.contains('xref') ||
            RegExp(r'/Type\s*/XRef\b').hasMatch(prefix));
  }

  static bool _validJpeg(Uint8List bytes) {
    if (bytes.length < 12 ||
        bytes[0] != 0xff ||
        bytes[1] != 0xd8 ||
        bytes.last != 0xd9 ||
        bytes[bytes.length - 2] != 0xff) {
      return false;
    }
    var offset = 2;
    var sawFrame = false;
    var sawScan = false;
    while (offset < bytes.length) {
      if (bytes[offset++] != 0xff) return false;
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) return false;
      final marker = bytes[offset++];
      if (marker == 0xd9) return sawFrame && sawScan && offset == bytes.length;
      if (marker == 0xd8 || marker == 0x00) return false;
      if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
      if (offset + 2 > bytes.length) return false;
      final length = (bytes[offset] << 8) | bytes[offset + 1];
      if (length < 2 || offset + length > bytes.length) return false;
      if ((marker >= 0xc0 && marker <= 0xc3) ||
          (marker >= 0xc5 && marker <= 0xc7) ||
          (marker >= 0xc9 && marker <= 0xcb) ||
          (marker >= 0xcd && marker <= 0xcf)) {
        if (length < 8) return false;
        final components = bytes[offset + 7];
        final width = (bytes[offset + 5] << 8) | bytes[offset + 6];
        if (components < 1 ||
            components > 4 ||
            length != 8 + (3 * components) ||
            width == 0) {
          return false;
        }
        sawFrame = true;
      }
      if (marker == 0xda) {
        if (!sawFrame || length < 6) return false;
        final components = bytes[offset + 2];
        if (components < 1 ||
            components > 4 ||
            length != 6 + (2 * components)) {
          return false;
        }
      }
      offset += length;
      if (marker != 0xda) continue;
      sawScan = true;
      while (offset < bytes.length - 1) {
        if (bytes[offset] != 0xff) {
          offset++;
          continue;
        }
        final next = bytes[offset + 1];
        if (next == 0x00 || next == 0xff || (next >= 0xd0 && next <= 0xd7)) {
          offset += 2;
          continue;
        }
        break;
      }
    }
    return false;
  }

  static bool _validPng(Uint8List bytes) {
    const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    if (!_startsWith(bytes, signature)) return false;
    var offset = signature.length;
    var chunks = 0;
    var sawIdat = false;
    while (offset + 12 <= bytes.length) {
      final length = _uint32BigEndian(bytes, offset);
      final dataStart = offset + 8;
      final dataEnd = dataStart + length;
      if (length < 0 || dataEnd + 4 > bytes.length) return false;
      final type = ascii.decode(bytes.sublist(offset + 4, offset + 8));
      if (_crc32(bytes, offset + 4, dataEnd) !=
          _uint32BigEndian(bytes, dataEnd)) {
        return false;
      }
      if (chunks++ == 0) {
        if (type != 'IHDR' ||
            length != 13 ||
            !_validPngHeader(bytes, dataStart)) {
          return false;
        }
      } else if (type == 'IHDR') {
        return false;
      }
      if (type == 'IDAT') sawIdat = true;
      offset = dataEnd + 4;
      if (type == 'IEND') {
        return length == 0 && sawIdat && offset == bytes.length;
      }
    }
    return false;
  }

  static bool _validWebp(Uint8List bytes) {
    if (bytes.length < 20 ||
        !_startsWith(bytes, const [0x52, 0x49, 0x46, 0x46]) ||
        bytes[8] != 0x57 ||
        bytes[9] != 0x45 ||
        bytes[10] != 0x42 ||
        bytes[11] != 0x50 ||
        _uint32LittleEndian(bytes, 4) != bytes.length - 8) {
      return false;
    }
    var offset = 12;
    var imageChunks = 0;
    while (offset + 8 <= bytes.length) {
      final type = ascii.decode(bytes.sublist(offset, offset + 4));
      final length = _uint32LittleEndian(bytes, offset + 4);
      final dataStart = offset + 8;
      final dataEnd = dataStart + length;
      final paddedEnd = dataEnd + (length.isOdd ? 1 : 0);
      if (length < 0 || paddedEnd > bytes.length) return false;
      if (type == 'VP8 ') {
        if (!_validVp8(bytes, dataStart, length)) {
          return false;
        }
        imageChunks++;
      } else if (type == 'VP8L') {
        if (!_validVp8l(bytes, dataStart, length)) return false;
        imageChunks++;
      } else if (type == 'ANMF') {
        if (length < 24 || !_validWebpFrame(bytes, dataStart + 16, dataEnd)) {
          return false;
        }
        imageChunks++;
      }
      offset = paddedEnd;
    }
    return offset == bytes.length && imageChunks > 0;
  }

  static bool _validVp8(Uint8List bytes, int start, int length) {
    if (length < 10 ||
        bytes[start] & 1 != 0 ||
        bytes[start + 3] != 0x9d ||
        bytes[start + 4] != 0x01 ||
        bytes[start + 5] != 0x2a) {
      return false;
    }
    final width = bytes[start + 6] | ((bytes[start + 7] & 0x3f) << 8);
    final height = bytes[start + 8] | ((bytes[start + 9] & 0x3f) << 8);
    return width > 0 && height > 0;
  }

  static bool _validVp8l(Uint8List bytes, int start, int length) {
    if (length < 5 || bytes[start] != 0x2f || bytes[start + 4] >> 5 != 0) {
      return false;
    }
    final width = 1 + bytes[start + 1] + ((bytes[start + 2] & 0x3f) << 8);
    final height =
        1 +
        (bytes[start + 2] >> 6) +
        (bytes[start + 3] << 2) +
        ((bytes[start + 4] & 0x0f) << 10);
    return width > 0 && height > 0;
  }

  static bool _validWebpFrame(Uint8List bytes, int start, int end) {
    var offset = start;
    var imageChunks = 0;
    while (offset + 8 <= end) {
      final type = ascii.decode(bytes.sublist(offset, offset + 4));
      final length = _uint32LittleEndian(bytes, offset + 4);
      final dataStart = offset + 8;
      final dataEnd = dataStart + length;
      final paddedEnd = dataEnd + (length.isOdd ? 1 : 0);
      if (paddedEnd > end) return false;
      if (type == 'VP8 ') {
        if (!_validVp8(bytes, dataStart, length)) return false;
        imageChunks++;
      } else if (type == 'VP8L') {
        if (!_validVp8l(bytes, dataStart, length)) return false;
        imageChunks++;
      } else if (type != 'ALPH') {
        return false;
      }
      offset = paddedEnd;
    }
    return offset == end && imageChunks == 1;
  }

  static String? _safeText(Uint8List bytes) {
    try {
      final value = utf8.decode(bytes, allowMalformed: false);
      if (value.runes.any(
        (rune) => rune < 0x20 && !const {0x09, 0x0a, 0x0d}.contains(rune),
      )) {
        return null;
      }
      return value;
    } catch (_) {
      return null;
    }
  }

  static bool _payloadMatches(String mimeType, Uint8List bytes) {
    switch (mimeType) {
      case 'application/pdf':
        return _validPdf(bytes);
      case 'image/jpeg':
        return _validJpeg(bytes);
      case 'image/png':
        return _validPng(bytes);
      case 'image/webp':
        return _validWebp(bytes);
      case 'text/plain':
      case 'text/csv':
        return _safeText(bytes) != null;
      case 'application/json':
        final text = _safeText(bytes);
        if (text == null) return false;
        try {
          jsonDecode(text);
          return true;
        } catch (_) {
          return false;
        }
      default:
        return false;
    }
  }

  @override
  Future<bool> download(
    Uri initial,
    WebPanelPolicy policy,
    bool Function() isCurrent,
  ) async {
    final client = _client();
    try {
      var uri = initial;
      for (var redirect = 0; redirect <= 3; redirect++) {
        if (!isCurrent() || !policy.allows(uri.toString())) return false;
        final request = http.Request('GET', uri)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers['Accept'] =
              'application/pdf,image/jpeg,image/png,image/webp,text/plain,text/csv,application/json';
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 30));
        if (!isCurrent()) return false;
        if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers['location'];
          if (location == null || redirect == 3) return false;
          uri = uri.resolve(location);
          continue;
        }
        final type = _downloadType(response.headers['content-type']);
        final length = response.contentLength;
        if (response.statusCode != 200 ||
            type == null ||
            (length != null &&
                (length < 1 || length > webPanelMaxTransferBytes))) {
          return false;
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          if (!isCurrent() ||
              bytes.length + chunk.length > webPanelMaxTransferBytes) {
            return false;
          }
          bytes.add(chunk);
        }
        if (!isCurrent() || bytes.length == 0) return false;
        final frozen = Uint8List.fromList(bytes.takeBytes());
        if (!_payloadMatches(type.$1, frozen)) return false;
        return await _saveFile(
              'web-panel-download.${type.$2}',
              type.$1,
              frozen,
            ) !=
            null;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }
}

final class WebPanelTransferController extends ChangeNotifier {
  WebPanelTransferController({
    required this.policy,
    required this.access,
    required this.uploadsEnabled,
    required this.downloadsEnabled,
    required this.isCurrent,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final WebPanelPolicy policy;
  final WebPanelTransferAccess access;
  final bool uploadsEnabled, downloadsEnabled;
  final bool Function() isCurrent;
  final DateTime Function() _now;
  WebPanelTransferStatus _status = WebPanelTransferStatus.idle;
  WebPanelTransferStatus get status => _status;
  DateTime? _expires;
  Timer? _timer;
  int _epoch = 0;
  bool _retired = false;

  bool get _current {
    try {
      return !_retired && isCurrent();
    } catch (_) {
      return false;
    }
  }

  void _set(WebPanelTransferStatus value) {
    if (_retired) return;
    _status = value;
    notifyListeners();
  }

  void _arm(WebPanelTransferStatus value, bool enabled) {
    if (!_current || !enabled || _status == WebPanelTransferStatus.working) {
      return;
    }
    _epoch++;
    _expires = _now().add(const Duration(seconds: 30));
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 30), () {
      if (_status == value) _set(WebPanelTransferStatus.idle);
    });
    _set(value);
  }

  void armUpload() => _arm(WebPanelTransferStatus.uploadArmed, uploadsEnabled);
  void armDownload() =>
      _arm(WebPanelTransferStatus.downloadArmed, downloadsEnabled);

  bool _consume(WebPanelTransferStatus value) {
    if (!_current ||
        _status != value ||
        _expires == null ||
        !_expires!.isAfter(_now())) {
      if (_status == value) _set(WebPanelTransferStatus.idle);
      return false;
    }
    _timer?.cancel();
    _expires = null;
    _set(WebPanelTransferStatus.working);
    return true;
  }

  Future<List<String>> selectUpload(FileSelectorParams request) async {
    if (!_consume(WebPanelTransferStatus.uploadArmed)) return const [];
    final operation = ++_epoch;
    try {
      final result = await access.pickUpload(request);
      if (!_current || operation != _epoch) return const [];
      _set(
        result.isEmpty
            ? WebPanelTransferStatus.denied
            : WebPanelTransferStatus.completed,
      );
      return result;
    } catch (_) {
      if (_current && operation == _epoch) {
        _set(WebPanelTransferStatus.failed);
      }
      return const [];
    }
  }

  /// Returns true when navigation was consumed as an explicit download.
  bool captureDownload(String rawUrl) {
    if (_status != WebPanelTransferStatus.downloadArmed) return false;
    if (!_consume(WebPanelTransferStatus.downloadArmed)) return true;
    if (!policy.allows(rawUrl)) {
      _set(WebPanelTransferStatus.denied);
      return true;
    }
    final operation = ++_epoch;
    unawaited(() async {
      bool saved;
      try {
        saved = await access.download(
          Uri.parse(rawUrl),
          policy,
          () => _current && operation == _epoch,
        );
      } catch (_) {
        saved = false;
      }
      if (!_current || operation != _epoch) return;
      _set(
        saved
            ? WebPanelTransferStatus.completed
            : WebPanelTransferStatus.failed,
      );
    }());
    return true;
  }

  void reset() {
    if (!_current || _status == WebPanelTransferStatus.working) return;
    _epoch++;
    _timer?.cancel();
    _expires = null;
    _set(WebPanelTransferStatus.idle);
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _epoch++;
    _timer?.cancel();
    _expires = null;
  }

  @override
  void dispose() {
    retire();
    super.dispose();
  }
}
