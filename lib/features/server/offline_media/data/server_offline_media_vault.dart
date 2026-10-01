import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/server_offline_media_models.dart';

final class _VaultDigestSink implements Sink<hashes.Digest> {
  hashes.Digest? value;

  @override
  void add(hashes.Digest data) => value = data;

  @override
  void close() {}
}

final class ServerOfflineMediaPlaybackLease {
  ServerOfflineMediaPlaybackLease._(this.uri, this._server, this._subscription);

  final Uri uri;
  final HttpServer _server;
  final StreamSubscription<HttpRequest> _subscription;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _server.close(force: true);
  }
}

final class ServerOfflineMediaVault {
  ServerOfflineMediaVault({
    FlutterSecureStorage? secureStorage,
    Future<Directory> Function()? root,
  }) : _secure = secureStorage ?? const FlutterSecureStorage(),
       _root = root ?? _defaultRoot;

  static const quotaBytes = 20 * 1024 * 1024 * 1024;
  static const maximumRecords = 256;
  static const maximumManifestBytes = 64 * 1024;
  static const _manifestName = 'completed.manifest.v1';
  final FlutterSecureStorage _secure;
  final Future<Directory> Function() _root;
  final _cipher = AesGcm.with256bits();

  static Future<Directory> _defaultRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/offline_media');
  }

  static void _grant(String value) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const FormatException('Invalid offline grant');
    }
  }

  String _keyName(String grantId) => 'larenor.offline-media.v1.$grantId';

  Future<SecretKey> _key(String grantId) async {
    _grant(grantId);
    final name = _keyName(grantId);
    final retained = await _secure.read(key: name);
    if (retained != null) {
      final bytes = base64Decode(retained);
      if (bytes.length != 32) {
        throw const FormatException('Invalid offline key');
      }
      return SecretKey(bytes);
    }
    final bytes = Uint8List.fromList(
      List.generate(32, (_) => Random.secure().nextInt(256), growable: false),
    );
    await _secure.write(key: name, value: base64Encode(bytes));
    return SecretKey(bytes);
  }

  Future<SecretKey> _existingKey(String grantId) async {
    _grant(grantId);
    final retained = await _secure.read(key: _keyName(grantId));
    if (retained == null) throw const FormatException('Missing offline key');
    try {
      final bytes = base64Decode(retained);
      if (bytes.length != 32) throw const FormatException();
      return SecretKey(bytes);
    } catch (_) {
      throw const FormatException('Invalid offline key');
    }
  }

  Future<Directory> _directory(String grantId) async {
    _grant(grantId);
    final root = await _root();
    final rootType = await FileSystemEntity.type(root.path, followLinks: false);
    if (rootType != FileSystemEntityType.notFound &&
        rootType != FileSystemEntityType.directory) {
      throw const FormatException('Invalid offline root');
    }
    final directory = Directory('${root.path}/$grantId');
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const FormatException('Invalid offline directory');
    }
    await directory.create(recursive: true);
    return directory;
  }

  Future<Directory?> _existingRoot() async {
    final root = await _root();
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) {
      throw const FormatException('Invalid offline root');
    }
    return root;
  }

  Future<Directory> _existingDirectory(String grantId) async {
    _grant(grantId);
    final root = await _existingRoot();
    if (root == null) throw const FormatException('Missing offline root');
    final directory = Directory('${root.path}/$grantId');
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException('Missing offline directory');
    }
    return directory;
  }

  Future<List<Directory>> _grantDirectories() async {
    final root = await _existingRoot();
    if (root == null) return const [];
    final result = <Directory>[];
    await for (final entry in root.list(followLinks: false)) {
      if (result.length >= maximumRecords) {
        throw const FormatException('Offline record limit exceeded');
      }
      final name = entry.path.split(Platform.pathSeparator).last;
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(name) || entry is! Directory) {
        throw const FormatException('Invalid offline record');
      }
      if (await FileSystemEntity.type(entry.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FormatException('Invalid offline record');
      }
      result.add(entry);
    }
    result.sort((left, right) => left.path.compareTo(right.path));
    return result;
  }

  Future<int> usedBytes() async {
    final root = await _existingRoot();
    if (root == null) return 0;
    var total = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) total += await entity.length();
      if (total > quotaBytes) return quotaBytes;
    }
    return total;
  }

  Future<void> writeChunk(String grantId, int offset, Uint8List bytes) async {
    if (offset < 0 || bytes.isEmpty || bytes.length > 32 * 1024) {
      throw const FormatException('Invalid offline chunk');
    }
    final directory = await _directory(grantId);
    final nonce = _cipher.newNonce();
    final box = await _cipher.encrypt(
      bytes,
      secretKey: await _key(grantId),
      nonce: nonce,
      aad: utf8.encode('$grantId:$offset'),
    );
    final encoded = Uint8List.fromList([
      ...nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ]);
    final target = File(
      '${directory.path}/${offset.toRadixString(16).padLeft(16, '0')}.chunk',
    );
    final temporary = File('${target.path}.partial');
    await temporary.writeAsBytes(encoded, flush: true);
    await temporary.rename(target.path);
  }

  /// Existing-only resumable read. Production hashing consumes one chunk at a
  /// time rather than retaining a complete multi-gigabyte download in memory.
  Stream<Uint8List> streamChunks(String grantId) async* {
    _grant(grantId);
    final root = await _existingRoot();
    if (root == null) return;
    final directory = Directory('${root.path}/$grantId');
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      throw const FormatException('Invalid offline directory');
    }
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (entity is! File) throw const FormatException('Invalid offline chunk');
      if (name == _manifestName ||
          name == '$_manifestName.partial' ||
          RegExp(r'^[0-9a-f]{16}\.chunk\.partial$').hasMatch(name)) {
        continue;
      }
      if (!RegExp(r'^[0-9a-f]{16}\.chunk$').hasMatch(name) ||
          files.length >= quotaBytes ~/ (16 * 1024)) {
        throw const FormatException('Invalid offline chunk');
      }
      files.add(entity);
    }
    files.sort((left, right) => left.path.compareTo(right.path));
    if (files.isEmpty) return;
    var offset = 0;
    final key = await _existingKey(grantId);
    for (final file in files) {
      final expected = '${offset.toRadixString(16).padLeft(16, '0')}.chunk';
      if (file.path.split(Platform.pathSeparator).last != expected) {
        throw const FormatException('Invalid offline chunk sequence');
      }
      final bytes = await _readExistingChunk(directory, grantId, offset, key);
      offset += bytes.length;
      if (offset > quotaBytes) {
        throw const FormatException('Offline quota exceeded');
      }
      yield bytes;
    }
  }

  Future<List<Uint8List>> readChunks(String grantId) =>
      streamChunks(grantId).toList();

  Future<Uint8List> _readBoundedFile(File file, int maximumBytes) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('Invalid offline file');
    }
    final handle = await file.open();
    try {
      final length = await handle.length();
      if (length <= 28 || length > maximumBytes) {
        throw const FormatException('Invalid offline file');
      }
      final bytes = await handle.read(maximumBytes + 1);
      if (bytes.length != length ||
          await handle.length() != length ||
          await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const FormatException('Changed offline file');
      }
      return bytes;
    } finally {
      await handle.close();
    }
  }

  Future<ServerOfflineMediaManifest?> _readManifest(Directory directory) async {
    final grantId = directory.path.split(Platform.pathSeparator).last;
    _grant(grantId);
    final target = File('${directory.path}/$_manifestName');
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw const FormatException('Invalid offline manifest');
    }
    final raw = await _readBoundedFile(target, maximumManifestBytes + 28);
    final clear = await _cipher.decrypt(
      SecretBox(
        raw.sublist(28),
        nonce: raw.sublist(0, 12),
        mac: Mac(raw.sublist(12, 28)),
      ),
      secretKey: await _existingKey(grantId),
      aad: utf8.encode('$grantId:manifest:v1'),
    );
    if (clear.length > maximumManifestBytes) {
      throw const FormatException('Invalid offline manifest');
    }
    final decoded = jsonDecode(utf8.decode(clear));
    final manifest = ServerOfflineMediaManifest.fromStorageJson(decoded);
    if (manifest.grantId != grantId || !manifest.complete) {
      throw const FormatException('Invalid offline manifest');
    }
    return manifest;
  }

  Future<Uint8List> _readExistingChunk(
    Directory directory,
    String grantId,
    int offset,
    SecretKey key,
  ) async {
    final file = File(
      '${directory.path}/${offset.toRadixString(16).padLeft(16, '0')}.chunk',
    );
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('Missing offline chunk');
    }
    final raw = await _readBoundedFile(file, 32 * 1024 + 28);
    final clear = await _cipher.decrypt(
      SecretBox(
        raw.sublist(28),
        nonce: raw.sublist(0, 12),
        mac: Mac(raw.sublist(12, 28)),
      ),
      secretKey: key,
      aad: utf8.encode('$grantId:$offset'),
    );
    if (clear.isEmpty || clear.length > 32 * 1024) {
      throw const FormatException('Invalid offline chunk');
    }
    return Uint8List.fromList(clear);
  }

  Future<void> _verifyCompleted(ServerOfflineMediaManifest manifest) async {
    if (!manifest.complete ||
        manifest.downloadedBytes != manifest.contentLength) {
      throw const FormatException('Invalid offline manifest');
    }
    final directory = await _existingDirectory(manifest.grantId);
    final maximumEntries =
        (manifest.contentLength + manifest.chunkBytes - 1) ~/
            manifest.chunkBytes +
        1;
    final entries = <FileSystemEntity>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entries.length >= maximumEntries) {
        throw const FormatException('Invalid offline chunks');
      }
      entries.add(entry);
    }
    final expectedFiles = <String>{_manifestName};
    final sink = _VaultDigestSink();
    final digest = hashes.sha256.startChunkedConversion(sink);
    final key = await _existingKey(manifest.grantId);
    var offset = 0;
    while (offset < manifest.contentLength) {
      final name = '${offset.toRadixString(16).padLeft(16, '0')}.chunk';
      expectedFiles.add(name);
      final clear = await _readExistingChunk(
        directory,
        manifest.grantId,
        offset,
        key,
      );
      final remaining = manifest.contentLength - offset;
      final expectedLength = min(manifest.chunkBytes, remaining);
      if (clear.length != expectedLength) {
        throw const FormatException('Invalid offline chunk');
      }
      digest.add(clear);
      offset += clear.length;
    }
    digest.close();
    for (final entry in entries) {
      final name = entry.path.split(Platform.pathSeparator).last;
      if (entry is! File || !expectedFiles.contains(name)) {
        throw const FormatException('Invalid offline chunks');
      }
    }
    if (offset != manifest.contentLength ||
        sink.value?.toString() != manifest.contentSha256) {
      throw const FormatException('Offline digest mismatch');
    }
  }

  Future<void> storeCompletedManifest(
    ServerOfflineMediaManifest manifest,
  ) async {
    if (!manifest.complete ||
        !DateTime.now().toUtc().isBefore(manifest.expiresAt)) {
      throw const FormatException('Invalid offline manifest');
    }
    await _verifyCompleted(manifest);
    final clear = utf8.encode(jsonEncode(manifest.toJson()));
    if (clear.length > maximumManifestBytes) {
      throw const FormatException('Invalid offline manifest');
    }
    final directory = await _existingDirectory(manifest.grantId);
    final nonce = _cipher.newNonce();
    final box = await _cipher.encrypt(
      clear,
      secretKey: await _existingKey(manifest.grantId),
      nonce: nonce,
      aad: utf8.encode('${manifest.grantId}:manifest:v1'),
    );
    final target = File('${directory.path}/$_manifestName');
    final temporary = File('${target.path}.partial');
    final partialType = await FileSystemEntity.type(
      temporary.path,
      followLinks: false,
    );
    if (partialType != FileSystemEntityType.notFound &&
        partialType != FileSystemEntityType.file) {
      throw const FormatException('Invalid offline manifest');
    }
    if (partialType == FileSystemEntityType.file) await temporary.delete();
    await temporary.writeAsBytes([
      ...nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ], flush: true);
    await temporary.rename(target.path);
  }

  Future<List<ServerOfflineMediaManifest>> completed(
    ServerOfflineMediaScope scope,
  ) async {
    final now = DateTime.now().toUtc();
    final result = <ServerOfflineMediaManifest>[];
    for (final directory in await _grantDirectories()) {
      final manifest = await _readManifest(directory);
      if (manifest == null || !scope.matches(manifest)) continue;
      if (!now.isBefore(manifest.expiresAt)) {
        await purge(manifest.grantId);
        continue;
      }
      result.add(manifest);
    }
    result.sort((left, right) => left.grantId.compareTo(right.grantId));
    return List.unmodifiable(result);
  }

  Future<ServerOfflineMediaManifest?> loadCompletedItem(
    ServerOfflineMediaScope scope,
    String itemId,
  ) async {
    final selected = (await completed(scope))
        .where((manifest) => manifest.itemId == itemId)
        .toList(growable: false);
    if (selected.isEmpty) return null;
    if (selected.length != 1) {
      throw const FormatException('Ambiguous offline manifest');
    }
    await _verifyCompleted(selected.single);
    return selected.single;
  }

  Future<void> purgeScope(ServerOfflineMediaScope scope) async {
    for (final directory in await _grantDirectories()) {
      final manifest = await _readManifest(directory);
      if (manifest != null && scope.matches(manifest)) {
        await purge(manifest.grantId);
      }
    }
  }

  Future<Uint8List> _readChunk(
    String grantId,
    int offset,
    SecretKey key,
  ) async {
    final directory = await _existingDirectory(grantId);
    return _readExistingChunk(directory, grantId, offset, key);
  }

  Future<ServerOfflineMediaPlaybackLease> openPlayback(
    ServerOfflineMediaManifest manifest,
  ) async {
    if (!manifest.complete ||
        !DateTime.now().toUtc().isBefore(manifest.expiresAt)) {
      throw const FormatException('Offline grant expired');
    }
    await _verifyCompleted(manifest);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final token = List.generate(
      32,
      (_) => Random.secure().nextInt(16).toRadixString(16),
      growable: false,
    ).join();
    final path = '/$token';
    late final StreamSubscription<HttpRequest> subscription;
    subscription = server.listen((request) async {
      try {
        if (request.uri.path != path ||
            request.uri.query.isNotEmpty ||
            !{'GET', 'HEAD'}.contains(request.method) ||
            !DateTime.now().toUtc().isBefore(manifest.expiresAt)) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        var start = 0;
        var end = manifest.contentLength - 1;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) {
          final match = RegExp(r'^bytes=([0-9]+)-([0-9]*)$').firstMatch(range);
          if (match == null) throw const FormatException('Invalid range');
          start = int.parse(match.group(1)!);
          if (match.group(2)!.isNotEmpty) end = int.parse(match.group(2)!);
          if (start > end || end >= manifest.contentLength) {
            request.response.statusCode =
                HttpStatus.requestedRangeNotSatisfiable;
            await request.response.close();
            return;
          }
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${manifest.contentLength}',
          );
        }
        final key = await _existingKey(manifest.grantId);
        request.response.headers
          ..contentType = ContentType.parse(manifest.contentType)
          ..contentLength = end - start + 1
          ..set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..set(HttpHeaders.cacheControlHeader, 'no-store');
        if (request.method == 'HEAD') {
          await request.response.close();
          return;
        }
        var chunkOffset = (start ~/ manifest.chunkBytes) * manifest.chunkBytes;
        while (chunkOffset <= end) {
          if (!DateTime.now().toUtc().isBefore(manifest.expiresAt)) {
            throw const FormatException('Offline grant expired');
          }
          final clear = await _readChunk(manifest.grantId, chunkOffset, key);
          final from = start > chunkOffset ? start - chunkOffset : 0;
          final to = min(clear.length, end - chunkOffset + 1);
          if (from >= to) throw const FormatException('Invalid range');
          request.response.add(clear.sublist(from, to));
          await request.response.flush();
          chunkOffset += clear.length;
        }
        await request.response.close();
      } catch (_) {
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.contentLength = 0;
          await request.response.close();
        } catch (_) {}
      }
    });
    return ServerOfflineMediaPlaybackLease._(
      Uri.parse('http://127.0.0.1:${server.port}$path'),
      server,
      subscription,
    );
  }

  Future<void> purge(String grantId) async {
    _grant(grantId);
    final root = await _existingRoot();
    if (root != null) {
      final directory = Directory('${root.path}/$grantId');
      final type = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.link) {
        await Link(directory.path).delete();
      } else if (type == FileSystemEntityType.directory) {
        await directory.delete(recursive: true);
      } else if (type != FileSystemEntityType.notFound) {
        throw const FormatException('Invalid offline directory');
      }
    }
    await _secure.delete(key: _keyName(grantId));
  }
}
