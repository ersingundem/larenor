import 'dart:async';
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
      'application/octet-stream' => ('application/octet-stream', 'bin'),
      _ => null,
    };
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
              'application/pdf,image/jpeg,image/png,image/webp,text/plain,text/csv,application/json,application/octet-stream';
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
    final result = await access.pickUpload(request);
    if (!_current || operation != _epoch) return const [];
    _set(
      result.isEmpty
          ? WebPanelTransferStatus.denied
          : WebPanelTransferStatus.completed,
    );
    return result;
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
      final saved = await access.download(
        Uri.parse(rawUrl),
        policy,
        () => _current && operation == _epoch,
      );
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
