import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../data/remote_profiles.dart';
import 'ssh_key_parser.dart';
import 'ssh_security_store.dart';
import 'ssh_tunnel_models.dart';

abstract class SshTunnelHandle {
  String get localAddress;
  int get localPort;
  Future<void> get done;
  void close();
}

abstract class SshTunnelEngine {
  Future<SshTunnelHandle> start(
    RemoteProfile profile,
    SshCredential credential,
    SshTunnelProfile tunnel, {
    required Future<bool> Function(SshHostPin pin) verifyHost,
    required bool Function() isCurrent,
  });
  void close();
}

class DartSshTunnelEngine implements SshTunnelEngine {
  DartSshTunnelEngine({Future<SSHSocket> Function(String, int)? connectSocket})
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
  _LocalTunnelHandle? _handle;
  bool _closed = false, _used = false;
  SshFailure? _verificationFailure;

  void _check(bool Function() current) {
    bool valid = false;
    try {
      valid = current();
    } catch (_) {}
    if (_closed || !valid) throw const SshFailure('retired');
  }

  @override
  Future<SshTunnelHandle> start(
    RemoteProfile profile,
    SshCredential credential,
    SshTunnelProfile tunnel, {
    required Future<bool> Function(SshHostPin pin) verifyHost,
    required bool Function() isCurrent,
  }) async {
    if (_used) throw const SshFailure('closed');
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
        throw const SshFailure('cancelled');
      }
      _socket = socket;
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
            : () => trusted ? credential.secret : null,
      );
      _client = client;
      await client.authenticated;
      _check(isCurrent);
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        tunnel.localPort,
        shared: false,
      );
      _check(isCurrent);
      final handle = _LocalTunnelHandle(
        server,
        client,
        tunnel,
        isCurrent,
        closeOwner: close,
      );
      _handle = handle;
      return handle;
    } catch (error) {
      final safe =
          _verificationFailure ??
          (error is SshFailure
              ? error
              : error is SocketException
              ? const SshFailure('bind_failed')
              : const SshFailure('connection_failed'));
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
    final handle = _handle;
    _handle = null;
    handle?._closeOwned();
    final client = _client;
    _client = null;
    if (client != null) unawaited(client.close().catchError((Object _) {}));
    _socket?.destroy();
    _socket = null;
  }
}

class _LocalTunnelHandle implements SshTunnelHandle {
  _LocalTunnelHandle(
    this._server,
    this._client,
    this._profile,
    this._isCurrent, {
    required this.closeOwner,
  }) {
    _subscription = _server.listen(_accept, onError: (_) => closeOwner());
    unawaited(_client.done.whenComplete(closeOwner));
  }
  static const maxConnections = 8;
  final ServerSocket _server;
  final SSHClient _client;
  final SshTunnelProfile _profile;
  final bool Function() _isCurrent;
  final void Function() closeOwner;
  final _completion = Completer<void>();
  final _connections = <_TunnelConnection>{};
  late final StreamSubscription<Socket> _subscription;
  bool _closed = false;

  @override
  String get localAddress => SshTunnelProfile.loopbackAddress;
  @override
  int get localPort => _server.port;
  @override
  Future<void> get done => _completion.future;

  Future<void> _accept(Socket socket) async {
    if (_closed || !_isCurrent() || _connections.length >= maxConnections) {
      socket.destroy();
      if (!_isCurrent()) closeOwner();
      return;
    }
    try {
      final remote = await _client.forwardLocal(
        _profile.targetHost,
        _profile.targetPort,
        localHost: SshTunnelProfile.loopbackAddress,
        localPort: socket.port,
      );
      if (_closed || !_isCurrent()) {
        socket.destroy();
        remote.destroy();
        closeOwner();
        return;
      }
      late final _TunnelConnection connection;
      connection = _TunnelConnection(socket, remote, () {
        _connections.remove(connection);
      });
      _connections.add(connection);
    } catch (_) {
      socket.destroy();
    }
  }

  void _closeOwned() {
    if (_closed) return;
    _closed = true;
    unawaited(_subscription.cancel());
    unawaited(_server.close());
    for (final connection in _connections.toList()) {
      connection.close();
    }
    _connections.clear();
    if (!_completion.isCompleted) _completion.complete();
  }

  @override
  void close() => closeOwner();
}

class _TunnelConnection {
  _TunnelConnection(this.local, this.remote, this.onClose) {
    localSub = local.listen(
      remote.sink.add,
      onDone: close,
      onError: (_) => close(),
      cancelOnError: true,
    );
    remoteSub = remote.stream.listen(
      local.add,
      onDone: close,
      onError: (_) => close(),
      cancelOnError: true,
    );
  }
  final Socket local;
  final SSHForwardChannel remote;
  final void Function() onClose;
  late final StreamSubscription<List<int>> localSub;
  late final StreamSubscription<List<int>> remoteSub;
  bool closed = false;
  void close() {
    if (closed) return;
    closed = true;
    unawaited(localSub.cancel());
    unawaited(remoteSub.cancel());
    local.destroy();
    remote.destroy();
    onClose();
  }
}
