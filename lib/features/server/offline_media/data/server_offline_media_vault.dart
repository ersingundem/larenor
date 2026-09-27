import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/server_offline_media_models.dart';

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

  Future<Directory> _directory(String grantId) async {
    _grant(grantId);
    final root = await _root();
    final directory = Directory('${root.path}/$grantId');
    await directory.create(recursive: true);
    return directory;
  }

  Future<int> usedBytes() async {
    final root = await _root();
    if (!await root.exists()) return 0;
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

  Future<List<Uint8List>> readChunks(String grantId) async {
    final directory = await _directory(grantId);
    final files = await directory
        .list(followLinks: false)
        .where((entity) => entity is File && entity.path.endsWith('.chunk'))
        .cast<File>()
        .toList();
    files.sort((left, right) => left.path.compareTo(right.path));
    final result = <Uint8List>[];
    var offset = 0;
    final key = await _key(grantId);
    for (final file in files) {
      final raw = await file.readAsBytes();
      if (raw.length <= 28) {
        throw const FormatException('Invalid offline chunk');
      }
      final nonce = raw.sublist(0, 12);
      final mac = Mac(raw.sublist(12, 28));
      final clear = await _cipher.decrypt(
        SecretBox(raw.sublist(28), nonce: nonce, mac: mac),
        secretKey: key,
        aad: utf8.encode('$grantId:$offset'),
      );
      final bytes = Uint8List.fromList(clear);
      result.add(bytes);
      offset += bytes.length;
    }
    return result;
  }

  Future<Uint8List> _readChunk(
    String grantId,
    int offset,
    SecretKey key,
  ) async {
    final directory = await _directory(grantId);
    final file = File(
      '${directory.path}/${offset.toRadixString(16).padLeft(16, '0')}.chunk',
    );
    final raw = await file.readAsBytes();
    if (raw.length <= 28) {
      throw const FormatException('Invalid offline chunk');
    }
    final clear = await _cipher.decrypt(
      SecretBox(
        raw.sublist(28),
        nonce: raw.sublist(0, 12),
        mac: Mac(raw.sublist(12, 28)),
      ),
      secretKey: key,
      aad: utf8.encode('$grantId:$offset'),
    );
    return Uint8List.fromList(clear);
  }

  Future<ServerOfflineMediaPlaybackLease> openPlayback(
    ServerOfflineMediaManifest manifest,
  ) async {
    if (!manifest.complete ||
        !DateTime.now().toUtc().isBefore(manifest.expiresAt)) {
      throw const FormatException('Offline grant expired');
    }
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
        request.response.headers
          ..contentType = ContentType.parse(manifest.contentType)
          ..contentLength = end - start + 1
          ..set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..set(HttpHeaders.cacheControlHeader, 'no-store');
        if (request.method == 'HEAD') {
          await request.response.close();
          return;
        }
        final key = await _key(manifest.grantId);
        var chunkOffset = (start ~/ manifest.chunkBytes) * manifest.chunkBytes;
        while (chunkOffset <= end) {
          final clear = await _readChunk(manifest.grantId, chunkOffset, key);
          final from = start > chunkOffset ? start - chunkOffset : 0;
          final to = min(clear.length, end - chunkOffset + 1);
          if (from >= to) throw const FormatException('Invalid range');
          request.response.add(clear.sublist(from, to));
          chunkOffset += clear.length;
        }
        await request.response.close();
      } catch (_) {
        try {
          request.response.statusCode = HttpStatus.internalServerError;
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
    final root = await _root();
    final directory = Directory('${root.path}/$grantId');
    if (await directory.exists()) await directory.delete(recursive: true);
    await _secure.delete(key: _keyName(grantId));
  }
}
