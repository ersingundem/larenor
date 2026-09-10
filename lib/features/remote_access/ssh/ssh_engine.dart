import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_key_parser.dart';
import '../data/remote_profiles.dart';
import 'ssh_security_store.dart';

abstract class SshChannel {
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<void> get done;
  void write(Uint8List bytes);
  void resize(SshTerminalSize size);
  void close();
}

class SshTerminalSize {
  const SshTerminalSize({
    required this.columns,
    required this.rows,
    this.pixelWidth = 0,
    this.pixelHeight = 0,
  });

  static const standard = SshTerminalSize(columns: 80, rows: 24);
  static const minColumns = 20, maxColumns = 500, minRows = 5, maxRows = 200;
  static const maxPixels = 16384;
  final int columns;
  final int rows;
  final int pixelWidth;
  final int pixelHeight;

  bool get isValid =>
      columns >= minColumns &&
      columns <= maxColumns &&
      rows >= minRows &&
      rows <= maxRows &&
      pixelWidth >= 0 &&
      pixelWidth <= maxPixels &&
      pixelHeight >= 0 &&
      pixelHeight <= maxPixels;

  @override
  bool operator ==(Object other) =>
      other is SshTerminalSize &&
      columns == other.columns &&
      rows == other.rows &&
      pixelWidth == other.pixelWidth &&
      pixelHeight == other.pixelHeight;

  @override
  int get hashCode => Object.hash(columns, rows, pixelWidth, pixelHeight);
}

abstract class SshEngine {
  Future<SshChannel> open(
    RemoteProfile profile,
    SshCredential credential, {
    required Future<bool> Function(SshHostPin) verifyHost,
    required bool Function() isCurrent,
    SshTerminalSize initialSize = SshTerminalSize.standard,
  });
  void close();
}

/// One attempt, one shell. No commands, forwarding, retry or debug callbacks.
class DartSshEngine implements SshEngine {
  DartSshEngine({Future<SSHSocket> Function(String, int)? connectSocket})
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
  SshKeyParseTask? _parse;
  bool _closed = false, _used = false;
  Completer<SshChannel>? _result;
  final _channelDone = Completer<void>();
  SshFailure? _verificationFailure;
  bool _sessionEnded = false;
  void _check(bool Function() current) {
    bool allowed = false;
    try {
      allowed = current();
    } catch (_) {}
    if (_closed || !allowed) throw const SshFailure('retired');
  }

  @override
  Future<SshChannel> open(
    RemoteProfile profile,
    SshCredential credential, {
    required Future<bool> Function(SshHostPin) verifyHost,
    required bool Function() isCurrent,
    SshTerminalSize initialSize = SshTerminalSize.standard,
  }) {
    if (!initialSize.isValid) {
      return Future.error(const SshFailure('invalid_terminal_size'));
    }
    if (_used) return Future.error(const SshFailure('closed'));
    _used = true;
    final result = Completer<SshChannel>();
    _result = result;
    void failure(Object error) {
      final safe =
          _verificationFailure ??
          (error is SshFailure ? error : const SshFailure('connection_failed'));
      if (!result.isCompleted) {
        result.completeError(safe);
      } else if (!_closed && !_channelDone.isCompleted) {
        _channelDone.completeError(const SshFailure('connection_lost'));
      }
      close();
    }

    // Upstream channel protocol errors may be emitted in its internal listeners.
    // This owned zone converts those errors to a closed attempt, never raw UI logs.
    runZonedGuarded(
      () {
        Future<void>(() async {
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
            return;
          }
          _socket = socket;
          _check(isCurrent);
          bool trusted = false;
          final client = SSHClient(
            socket,
            username: profile.username,
            identities: identities,
            handshakeTimeout: const Duration(seconds: 45),
            authTimeout: const Duration(seconds: 15),
            keepAliveInterval: null,
            onVerifyHostKey: (type, bytes) async {
              _check(isCurrent);
              bool accepted;
              try {
                accepted = await verifyHost(
                  SshHostPin(type, utf8.decode(bytes)),
                );
              } on SshFailure catch (e) {
                _verificationFailure = e;
                rethrow;
              }
              _check(isCurrent);
              trusted = accepted;
              return accepted;
            },
            onPasswordRequest: credential.kind != SshCredentialKind.password
                ? null
                : () {
                    _check(isCurrent);
                    return trusted ? credential.secret : null;
                  },
          );
          _client = client;
          unawaited(
            client.done.then((_) {
              if (!_closed && !_sessionEnded) {
                failure(const SshFailure('connection_failed'));
              }
            }, onError: failure),
          );
          final session = await client.shell(
            pty: SSHPtyConfig(
              type: 'xterm-256color',
              width: initialSize.columns,
              height: initialSize.rows,
              pixelWidth: initialSize.pixelWidth,
              pixelHeight: initialSize.pixelHeight,
            ),
          );
          if (_closed) {
            session.close();
            return;
          }
          _check(isCurrent);
          unawaited(
            session.done.then((_) {
              _sessionEnded = true;
              if (!_channelDone.isCompleted) _channelDone.complete();
            }, onError: failure),
          );
          if (!result.isCompleted) {
            result.complete(_DartSshChannel(session, this));
          }
        }).catchError((Object e) {
          failure(e);
        });
      },
      (error, stack) {
        failure(error);
      },
    );
    return result.future;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _parse?.cancel();
    _parse = null;
    _socket?.destroy();
    _socket = null;
    final client = _client;
    _client = null;
    if (client != null) unawaited(client.close().catchError((Object _) {}));
    if (!_channelDone.isCompleted) _channelDone.complete();
    if (_result?.isCompleted == false) {
      _result!.completeError(const SshFailure('cancelled'));
    }
  }
}

class _DartSshChannel extends SshChannel {
  _DartSshChannel(this.session, this.owner);
  final SSHSession session;
  final DartSshEngine owner;
  @override
  Stream<List<int>> get stdout => session.stdout;
  @override
  Stream<List<int>> get stderr => session.stderr;
  @override
  Future<void> get done => owner._channelDone.future;
  @override
  void write(Uint8List bytes) {
    if (owner._closed) throw const SshFailure('closed');
    session.write(bytes);
  }

  @override
  void resize(SshTerminalSize size) {
    if (owner._closed) throw const SshFailure('closed');
    if (!size.isValid) throw const SshFailure('invalid_terminal_size');
    session.resizeTerminal(
      size.columns,
      size.rows,
      size.pixelWidth,
      size.pixelHeight,
    );
  }

  @override
  void close() => owner.close();
}
