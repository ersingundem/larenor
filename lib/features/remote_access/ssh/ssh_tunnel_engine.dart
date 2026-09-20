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
  DartSshTunnelEngine({
    Future<SSHSocket> Function(String, int)? connectSocket,
    Future<ServerSocket> Function(int port)? bindServer,
  }) : _connectSocket =
           connectSocket ??
           ((host, port) => SSHSocket.connect(
             host,
             port,
             timeout: const Duration(seconds: 10),
           )),
       _bindServer =
           bindServer ??
           ((port) => ServerSocket.bind(
             InternetAddress.loopbackIPv4,
             port,
             shared: false,
           ));
  final Future<SSHSocket> Function(String, int) _connectSocket;
  final Future<ServerSocket> Function(int port) _bindServer;
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
    ServerSocket? pendingServer;
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
            : () {
                _check(isCurrent);
                return trusted ? credential.secret : null;
              },
      );
      _client = client;
      await client.authenticated;
      _check(isCurrent);
      final server = pendingServer = await _bindServer(tunnel.localPort);
      _check(isCurrent);
      final handle = _LocalTunnelHandle(
        server,
        client,
        tunnel,
        isCurrent,
        closeOwner: close,
      );
      _handle = handle;
      pendingServer = null;
      return handle;
    } catch (error) {
      if (pendingServer case final server?) {
        await server.close().catchError((Object _) => server);
      }
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

  bool _current() {
    if (_closed) return false;
    try {
      return _isCurrent();
    } catch (_) {
      return false;
    }
  }

  @override
  String get localAddress => SshTunnelProfile.loopbackAddress;
  @override
  int get localPort => _server.port;
  @override
  Future<void> get done => _completion.future;

  Future<void> _accept(Socket socket) async {
    final current = _current();
    if (!current || _connections.length >= maxConnections) {
      socket.destroy();
      if (!current) closeOwner();
      return;
    }
    try {
      final remote = await _client.forwardLocal(
        _profile.targetHost,
        _profile.targetPort,
        localHost: SshTunnelProfile.loopbackAddress,
        localPort: socket.port,
      );
      if (!_current()) {
        socket.destroy();
        remote.destroy();
        closeOwner();
        return;
      }
      late final _TunnelConnection connection;
      connection = _TunnelConnection(
        socket,
        remote,
        () {
          _connections.remove(connection);
        },
        isCurrent: _current,
        retireOwner: closeOwner,
      );
      _connections.add(connection);
    } catch (_) {
      socket.destroy();
    }
  }

  void _closeOwned() {
    if (_closed) return;
    _closed = true;
    final listenerClosed = _subscription.cancel();
    final serverClosed = _server.close().then<void>((_) {});
    for (final connection in _connections.toList()) {
      connection.close();
    }
    _connections.clear();
    unawaited(
      Future.wait<void>([listenerClosed, serverClosed]).whenComplete(() {
        if (!_completion.isCompleted) _completion.complete();
      }),
    );
  }

  @override
  void close() => closeOwner();
}

class _TunnelConnection {
  _TunnelConnection(
    this.local,
    this.remote,
    this.onClose, {
    required this.isCurrent,
    required this.retireOwner,
  }) {
    localSub = local.listen(
      (bytes) => _forward(bytes, remote.sink.add),
      onDone: close,
      onError: (_) => close(),
      cancelOnError: true,
    );
    remoteSub = remote.stream.listen(
      (bytes) => _forward(bytes, local.add),
      onDone: close,
      onError: (_) => close(),
      cancelOnError: true,
    );
  }
  final Socket local;
  final SSHForwardChannel remote;
  final void Function() onClose;
  final bool Function() isCurrent;
  final void Function() retireOwner;
  late final StreamSubscription<List<int>> localSub;
  late final StreamSubscription<List<int>> remoteSub;
  bool closed = false;

  void _forward(List<int> bytes, void Function(List<int>) send) {
    if (!isCurrent()) {
      retireOwner();
      return;
    }
    send(bytes);
  }

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
