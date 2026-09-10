import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' as ssh;
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/ssh/ssh_engine.dart';
import 'package:larenor/features/remote_access/ssh/ssh_security_store.dart';

const _password = SshCredential(
  SshCredentialKind.password,
  'synthetic-password-never-send-before-trust',
);
const _profile = RemoteProfile(
  id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  name: 'Synthetic SSH endpoint',
  protocol: RemoteProtocol.ssh,
  host: 'test.invalid',
  port: 2222,
  username: 'synthetic-user',
);

void main() {
  test('invalid initial PTY size fails before socket creation', () async {
    var calls = 0;
    final engine = DartSshEngine(
      connectSocket: (_, _) async {
        calls++;
        return _Socket();
      },
    );
    addTearDown(engine.close);
    await expectLater(
      _open(engine, initialSize: const SshTerminalSize(columns: 10, rows: 2)),
      throwsA(_failure('invalid_terminal_size')),
    );
    expect(calls, 0);
  });

  test('retired or throwing owner never calls the socket factory', () async {
    for (final current in <bool Function()>[
      () => false,
      () => throw StateError('private-owner-details'),
    ]) {
      var calls = 0;
      final engine = DartSshEngine(
        connectSocket: (_, _) async {
          calls++;
          return _Socket();
        },
      );
      addTearDown(engine.close);
      await expectLater(
        _open(engine, current: current),
        throwsA(_failure('retired')),
      );
      expect(calls, 0);
    }
  });

  test(
    'cancel pending connect destroys its late socket without SSH traffic',
    () async {
      final requested = Completer<void>();
      final pending = Completer<ssh.SSHSocket>();
      final socket = _Socket();
      var calls = 0;
      var trustCalls = 0;
      final engine = DartSshEngine(
        connectSocket: (host, port) {
          calls++;
          expect(host, _profile.host);
          expect(port, _profile.port);
          requested.complete();
          return pending.future;
        },
      );
      addTearDown(engine.close);
      final expectation = expectLater(
        _open(
          engine,
          verify: (_) async {
            trustCalls++;
            return true;
          },
        ),
        throwsA(_failure('cancelled')),
      );
      await requested.future;
      engine.close();
      engine.close();
      await expectation;
      pending.complete(socket);
      await socket.destroyed.future.timeout(const Duration(seconds: 1));
      expect(calls, 1);
      expect(trustCalls, 0);
      expect(socket.streamReads, 0);
      expect(socket.writes, isEmpty);
    },
  );

  test(
    'owner retirement while connect waits destroys the arriving socket',
    () async {
      var current = true;
      final requested = Completer<void>();
      final pending = Completer<ssh.SSHSocket>();
      final socket = _Socket();
      final engine = DartSshEngine(
        connectSocket: (_, _) {
          requested.complete();
          return pending.future;
        },
      );
      addTearDown(engine.close);
      final expectation = expectLater(
        _open(engine, current: () => current),
        throwsA(_failure('retired')),
      );
      await requested.future;
      current = false;
      pending.complete(socket);
      await expectation;
      await socket.destroyed.future;
      expect(socket.streamReads, 0);
      expect(socket.writes, isEmpty);
    },
  );

  test(
    'malformed peer handshake closes with a static error and no diagnostics',
    () async {
      final printed = <String>[];
      await runZoned(
        () async {
          final socket = _Socket();
          var trustCalls = 0;
          final engine = DartSshEngine(connectSocket: (_, _) async => socket);
          addTearDown(engine.close);
          final expectation = expectLater(
            _open(
              engine,
              verify: (_) async {
                trustCalls++;
                return true;
              },
            ),
            throwsA(
              _failure('connection_failed').having(
                (e) => e.toString(),
                'static description',
                'SshFailure(connection_failed)',
              ),
            ),
          );
          await socket.firstWrite.future.timeout(const Duration(seconds: 1));
          socket.receive(utf8.encode('SSH-9.9-private-peer-details\r\n'));
          await expectation;
          await socket.destroyed.future;
          expect(trustCalls, 0);
          expect(socket.streamReads, greaterThan(0));
          final traffic = socket.writes.expand((bytes) => bytes).toList();
          expect(latin1.decode(traffic), isNot(contains(_password.secret)));
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      );
      expect(printed, isEmpty);
    },
  );

  test('peer EOF during the real handshake never opens a shell or sends credentials', () async {
    final socket = _Socket();
    var trustCalls = 0;
    final engine = DartSshEngine(connectSocket: (_, _) async => socket);
    addTearDown(engine.close);
    final expectation = expectLater(
      _open(
        engine,
        verify: (_) async {
          trustCalls++;
          return true;
        },
      ),
      throwsA(_failure('connection_failed')),
    );
    await socket.firstWrite.future.timeout(const Duration(seconds: 1));
    await socket.peerClose();
    await expectation;
    await socket.destroyed.future;
    expect(trustCalls, 0);
    final traffic = socket.writes.expand((bytes) => bytes).toList();
    expect(latin1.decode(traffic), isNot(contains(_password.secret)));
  });

  test(
    'cancelling expensive private-key parsing never reaches socket creation',
    () async {
      // Deliberately expensive synthetic container. The real parser enters its
      // file-controlled bcrypt KDF; cancellation must kill that worker isolate.
      final costlyPem = ssh.OpenSSHKeyPairs(
        cipherName: 'aes256-ctr',
        kdfName: 'bcrypt',
        kdfOptions: ssh.OpenSSHBcryptKdfOptions(Uint8List(16), 0x7fffffff),
        publicKeys: [Uint8List(32)],
        privateKeyBlob: Uint8List(64),
      ).toPem();
      var calls = 0;
      final engine = DartSshEngine(
        connectSocket: (_, _) async {
          calls++;
          return _Socket();
        },
      );
      addTearDown(engine.close);
      final expectation = expectLater(
        _open(
          engine,
          credential: SshCredential(
            SshCredentialKind.privateKey,
            costlyPem,
            passphrase: 'synthetic phrase',
          ),
        ),
        throwsA(_failure('cancelled')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      engine.close();
      await expectation;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 0);
    },
  );
}

Future<SshChannel> _open(
  DartSshEngine engine, {
  SshCredential credential = _password,
  bool Function()? current,
  Future<bool> Function(SshHostPin)? verify,
  SshTerminalSize initialSize = SshTerminalSize.standard,
}) => engine.open(
  _profile,
  credential,
  isCurrent: current ?? () => true,
  verifyHost: verify ?? (_) async => false,
  initialSize: initialSize,
);

TypeMatcher<SshFailure> _failure(String code) =>
    isA<SshFailure>().having((e) => e.code, 'code', code);

class _Socket implements ssh.SSHSocket {
  _Socket() {
    _outgoing.stream.listen((bytes) {
      writes.add(List<int>.of(bytes));
      if (!firstWrite.isCompleted) firstWrite.complete();
    });
  }

  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>(sync: true);
  final _finished = Completer<void>();
  final destroyed = Completer<void>();
  final firstWrite = Completer<void>();
  final writes = <List<int>>[];
  var streamReads = 0;

  @override
  Stream<Uint8List> get stream {
    streamReads++;
    return _incoming.stream;
  }

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _finished.future;

  void receive(List<int> data) => _incoming.add(Uint8List.fromList(data));
  Future<void> peerClose() => _incoming.close();

  @override
  void destroy() {
    if (!destroyed.isCompleted) destroyed.complete();
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_outgoing.isClosed) unawaited(_outgoing.close());
    if (!_finished.isCompleted) _finished.complete();
  }

  @override
  Future<void> close() async => destroy();

  @override
  Future<void> flush() async {}
}
