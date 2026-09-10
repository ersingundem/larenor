import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../data/remote_profiles.dart';
import 'sftp_models.dart';
import 'ssh_key_parser.dart';
import 'ssh_security_store.dart';

abstract class SftpTransport {
  Future<void> get done;

  Future<SftpListing> list(
    String path, {
    required int maxEntries,
    required bool Function() isCurrent,
  });

  Future<Uint8List> download(
    String path, {
    required int maxBytes,
    required bool Function() isCurrent,
    required void Function(int transferred) onProgress,
  });

  Future<void> upload(
    String path,
    Uint8List bytes, {
    required int maxBytes,
    required bool Function() isCurrent,
    required void Function(int transferred) onProgress,
  });

  void close();
}

abstract class SftpEngine {
  Future<SftpTransport> open(
    RemoteProfile profile,
    SshCredential credential, {
    required Future<bool> Function(SshHostPin pin) verifyHost,
    required bool Function() isCurrent,
  });

  void close();
}

/// One authenticated connection and one SFTP subsystem. It never retries.
class DartSftpEngine implements SftpEngine {
  DartSftpEngine({Future<SSHSocket> Function(String, int)? connectSocket})
    : _connectSocket =
          connectSocket ??
          ((host, port) => SSHSocket.connect(
            host,
            port,
            timeout: const Duration(seconds: 10),
          ));

  final Future<SSHSocket> Function(String, int) _connectSocket;
  SSHSocket? _socket;
  SSHClient? _client;
  SftpClient? _sftp;
  SshKeyParseTask? _parse;
  bool _closed = false;
  bool _used = false;
  SshFailure? _verificationFailure;

  void _check(bool Function() current) {
    bool allowed = false;
    try {
      allowed = current();
    } catch (_) {}
    if (_closed || !allowed) throw const SftpFailure('retired');
  }

  @override
  Future<SftpTransport> open(
    RemoteProfile profile,
    SshCredential credential, {
    required Future<bool> Function(SshHostPin pin) verifyHost,
    required bool Function() isCurrent,
  }) async {
    if (_used) throw const SftpFailure('closed');
    _used = true;
    try {
      _check(isCurrent);
      List<SSHKeyPair>? identities;
      if (credential.kind == SshCredentialKind.privateKey) {
        _parse = SshKeyParseTask(
          credential.secret,
          passphrase: credential.passphrase,
        );
        identities = await _parse!.result;
        _parse = null;
        _check(isCurrent);
      }
      final socket = await _connectSocket(profile.host, profile.port);
      if (_closed) {
        socket.destroy();
        throw const SftpFailure('cancelled');
      }
      _socket = socket;
      _check(isCurrent);
      var trusted = false;
      final client = SSHClient(
        socket,
        username: profile.username,
        identities: identities,
        handshakeTimeout: const Duration(seconds: 45),
        authTimeout: const Duration(seconds: 15),
        keepAliveInterval: null,
        onVerifyHostKey: (type, bytes) async {
          _check(isCurrent);
          try {
            trusted = await verifyHost(SshHostPin(type, utf8.decode(bytes)));
            _check(isCurrent);
            return trusted;
          } on SshFailure catch (error) {
            _verificationFailure = error;
            rethrow;
          }
        },
        onPasswordRequest: credential.kind != SshCredentialKind.password
            ? null
            : () {
                _check(isCurrent);
                return trusted ? credential.secret : null;
              },
      );
      _client = client;
      final sftp = await client.sftp();
      _check(isCurrent);
      _sftp = sftp;
      return _DartSftpTransport(sftp, client, this);
    } catch (error) {
      final safe =
          _verificationFailure ??
          (error is SftpFailure
              ? error
              : error is SshFailure
              ? SftpFailure(error.code)
              : const SftpFailure('connection_failed'));
      close();
      throw safe;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _parse?.cancel();
    _parse = null;
    final sftp = _sftp;
    _sftp = null;
    if (sftp != null) unawaited(sftp.close().catchError((Object _) {}));
    final client = _client;
    _client = null;
    if (client != null) unawaited(client.close().catchError((Object _) {}));
    _socket?.destroy();
    _socket = null;
  }
}

class _DartSftpTransport implements SftpTransport {
  _DartSftpTransport(this._sftp, this._client, this._owner);
  final SftpClient _sftp;
  final SSHClient _client;
  final DartSftpEngine _owner;

  void _check(bool Function() current) {
    _owner._check(current);
  }

  @override
  Future<void> get done => _client.done;

  @override
  Future<SftpListing> list(
    String path, {
    required int maxEntries,
    required bool Function() isCurrent,
  }) async {
    if (maxEntries <= 0 || maxEntries > sftpMaxEntries) {
      throw const SftpFailure('invalid_limit');
    }
    final normalized = normalizeSftpPath(path);
    final entries = <SftpEntry>[];
    var truncated = false;
    _check(isCurrent);
    outer:
    await for (final chunk in _sftp.readdir(normalized)) {
      _check(isCurrent);
      for (final item in chunk) {
        if (item.filename == '.' || item.filename == '..') continue;
        final attr = item.attr;
        if (!attr.isDirectory && !attr.isFile) continue;
        if (entries.length == maxEntries) {
          truncated = true;
          break outer;
        }
        final itemPath = joinSftpPath(normalized, item.filename);
        entries.add(
          attr.isDirectory
              ? SftpEntry.directory(item.filename, itemPath)
              : SftpEntry.file(
                  item.filename,
                  itemPath,
                  size: attr.size,
                  modifiedAt: attr.modifyTime == null
                      ? null
                      : DateTime.fromMillisecondsSinceEpoch(
                          attr.modifyTime! * 1000,
                        ),
                ),
        );
      }
    }
    _check(isCurrent);
    return SftpListing(List.unmodifiable(entries), truncated: truncated);
  }

  @override
  Future<Uint8List> download(
    String path, {
    required int maxBytes,
    required bool Function() isCurrent,
    required void Function(int transferred) onProgress,
  }) async {
    if (maxBytes <= 0 || maxBytes > sftpMaxTransferBytes) {
      throw const SftpFailure('invalid_limit');
    }
    final normalized = normalizeSftpPath(path);
    _check(isCurrent);
    final attr = await _sftp.stat(normalized, followLink: false);
    _check(isCurrent);
    if (!attr.isFile) throw const SftpFailure('not_file');
    final length = attr.size;
    if (length == null || length < 0 || length > maxBytes) {
      throw const SftpFailure('file_too_large');
    }
    final file = await _sftp.open(normalized, mode: SftpFileOpenMode.read);
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in file.read(
        length: length,
        chunkSize: 32 * 1024,
        maxPendingRequests: 4,
      )) {
        _check(isCurrent);
        if (builder.length + chunk.length > maxBytes) {
          throw const SftpFailure('file_too_large');
        }
        builder.add(chunk);
        onProgress(builder.length);
      }
      _check(isCurrent);
      if (builder.length != length) throw const SftpFailure('file_changed');
      return builder.takeBytes();
    } catch (error) {
      if (error is SftpFailure) rethrow;
      throw const SftpFailure('transfer_failed');
    } finally {
      await file.close().catchError((Object _) {});
    }
  }

  @override
  Future<void> upload(
    String path,
    Uint8List bytes, {
    required int maxBytes,
    required bool Function() isCurrent,
    required void Function(int transferred) onProgress,
  }) async {
    if (maxBytes <= 0 || maxBytes > sftpMaxTransferBytes) {
      throw const SftpFailure('invalid_limit');
    }
    if (bytes.length > maxBytes) throw const SftpFailure('file_too_large');
    final normalized = normalizeSftpPath(path);
    _check(isCurrent);
    final file = await _sftp.open(
      normalized,
      mode:
          SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.exclusive,
    );
    try {
      await file.write(
        Stream.value(Uint8List.fromList(bytes)),
        onProgress: onProgress,
        chunkSize: 16 * 1024,
        maxPendingRequests: 4,
      );
      _check(isCurrent);
    } catch (error) {
      if (error is SftpFailure) rethrow;
      throw const SftpFailure('transfer_failed');
    } finally {
      await file.close().catchError((Object _) {});
    }
  }

  @override
  void close() => _owner.close();
}
