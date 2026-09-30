import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' as ssh;
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/ssh/sftp_engine.dart';
import 'package:larenor/features/remote_access/ssh/sftp_models.dart';
import 'package:larenor/features/remote_access/ssh/ssh_engine.dart';
import 'package:larenor/features/remote_access/ssh/ssh_security_store.dart';
import 'package:larenor/features/remote_access/ssh/ssh_tunnel_engine.dart';
import 'package:larenor/features/remote_access/ssh/ssh_tunnel_models.dart';

class _Fixture {
  const _Fixture({
    required this.port,
    required this.user,
    required this.keyPath,
    required this.keyPassphrase,
    required this.hostKeyType,
    required this.hostKeyFingerprint,
    required this.root,
    required this.tunnelPort,
    required this.targetPort,
    required this.password,
    required this.jumpPort,
    required this.jumpHostKeyType,
    required this.jumpHostKeyFingerprint,
    required this.mfaPort,
    required this.mfaHostKeyType,
    required this.mfaHostKeyFingerprint,
  });

  final int port;
  final String user;
  final String keyPath;
  final String keyPassphrase;
  final String hostKeyType;
  final String hostKeyFingerprint;
  final String root;
  final int tunnelPort;
  final int targetPort;
  final String password;
  final int jumpPort;
  final String jumpHostKeyType;
  final String jumpHostKeyFingerprint;
  final int mfaPort;
  final String mfaHostKeyType;
  final String mfaHostKeyFingerprint;

  static _Fixture? fromEnvironment() {
    final environment = Platform.environment;
    int? integer(String name) => int.tryParse(environment[name] ?? '');
    final port = integer('LARENOR_SSH_FIXTURE_PORT');
    final tunnelPort = integer('LARENOR_SSH_TUNNEL_PORT');
    final targetPort = integer('LARENOR_SSH_TARGET_PORT');
    final jumpPort = integer('LARENOR_SSH_JUMP_PORT');
    final mfaPort = integer('LARENOR_SSH_MFA_PORT');
    final required = <String>[
      'LARENOR_SSH_FIXTURE_USER',
      'LARENOR_SSH_PRIVATE_KEY',
      'LARENOR_SSH_KEY_PASSPHRASE',
      'LARENOR_SSH_HOST_KEY_TYPE',
      'LARENOR_SSH_HOST_KEY_FINGERPRINT',
      'LARENOR_SFTP_FIXTURE_ROOT',
      'LARENOR_SSH_FIXTURE_PASSWORD',
      'LARENOR_SSH_JUMP_HOST_KEY_TYPE',
      'LARENOR_SSH_JUMP_HOST_KEY_FINGERPRINT',
      'LARENOR_SSH_MFA_HOST_KEY_TYPE',
      'LARENOR_SSH_MFA_HOST_KEY_FINGERPRINT',
    ];
    if (port == null ||
        tunnelPort == null ||
        targetPort == null ||
        jumpPort == null ||
        mfaPort == null ||
        required.any((name) => (environment[name] ?? '').isEmpty)) {
      return null;
    }
    return _Fixture(
      port: port,
      user: environment['LARENOR_SSH_FIXTURE_USER']!,
      keyPath: environment['LARENOR_SSH_PRIVATE_KEY']!,
      keyPassphrase: environment['LARENOR_SSH_KEY_PASSPHRASE']!,
      hostKeyType: environment['LARENOR_SSH_HOST_KEY_TYPE']!,
      hostKeyFingerprint: environment['LARENOR_SSH_HOST_KEY_FINGERPRINT']!,
      root: environment['LARENOR_SFTP_FIXTURE_ROOT']!,
      tunnelPort: tunnelPort,
      targetPort: targetPort,
      password: environment['LARENOR_SSH_FIXTURE_PASSWORD']!,
      jumpPort: jumpPort,
      jumpHostKeyType: environment['LARENOR_SSH_JUMP_HOST_KEY_TYPE']!,
      jumpHostKeyFingerprint:
          environment['LARENOR_SSH_JUMP_HOST_KEY_FINGERPRINT']!,
      mfaPort: mfaPort,
      mfaHostKeyType: environment['LARENOR_SSH_MFA_HOST_KEY_TYPE']!,
      mfaHostKeyFingerprint:
          environment['LARENOR_SSH_MFA_HOST_KEY_FINGERPRINT']!,
    );
  }

  RemoteProfile get profile => RemoteProfile(
    id: '0123456789abcdef0123456789abcdef',
    name: 'Isolated OpenSSH fixture',
    protocol: RemoteProtocol.ssh,
    host: '127.0.0.1',
    port: port,
    username: user,
  );

  RemoteProfile profileAt(int value, String name) => RemoteProfile(
    id: value.toRadixString(16).padLeft(32, '0'),
    name: name,
    protocol: RemoteProtocol.ssh,
    host: '127.0.0.1',
    port: value,
    username: user,
  );

  SshCredential credential() => SshCredential(
    SshCredentialKind.privateKey,
    File(keyPath).readAsStringSync(),
    passphrase: keyPassphrase,
  );

  Future<bool> verify(SshHostPin pin) async {
    expect(pin.type, hostKeyType);
    expect(pin.fingerprint, hostKeyFingerprint);
    return true;
  }
}

void main() {
  final fixture = _Fixture.fromEnvironment();
  final nativeSkip = fixture == null
      ? 'Set the isolated OpenSSH fixture environment to run this test.'
      : false;

  test(
    'password, keyboard-interactive MFA and jump host are real protocol paths',
    () async {
      final passwordEngine = DartSshEngine();
      addTearDown(passwordEngine.close);
      final passwordChannel = await passwordEngine.open(
        fixture!.profile,
        SshCredential(SshCredentialKind.password, fixture.password),
        verifyHost: fixture.verify,
        isCurrent: () => true,
        answerChallenge: (_, _) async => null,
      );
      final passwordOutput = BytesBuilder(copy: false);
      final passwordSubscription = passwordChannel.stdout.listen(
        passwordOutput.add,
      );
      passwordChannel.write(
        Uint8List.fromList(utf8.encode("printf 'password-ok\\n'; exit\n")),
      );
      await passwordChannel.done.timeout(const Duration(seconds: 15));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await passwordSubscription.cancel();
      expect(utf8.decode(passwordOutput.takeBytes()), contains('password-ok'));

      final mfaEngine = DartSshEngine();
      addTearDown(mfaEngine.close);
      var mfaChallenges = 0;
      final mfaProfile = fixture.profileAt(fixture.mfaPort, 'MFA target');
      final mfaChannel = await mfaEngine.open(
        mfaProfile,
        fixture.credential(),
        verifyHost: (pin) async {
          expect(pin.type, fixture.mfaHostKeyType);
          expect(pin.fingerprint, fixture.mfaHostKeyFingerprint);
          return true;
        },
        isCurrent: () => true,
        answerChallenge: (hop, challenge) async {
          expect(hop, SshHop.target);
          expect(challenge.prompts, hasLength(1));
          mfaChallenges++;
          return [fixture.password];
        },
      );
      final mfaOutput = BytesBuilder(copy: false);
      final mfaSubscription = mfaChannel.stdout.listen(mfaOutput.add);
      mfaChannel.write(
        Uint8List.fromList(utf8.encode("printf 'mfa-ok\\n'; exit\n")),
      );
      await mfaChannel.done.timeout(const Duration(seconds: 15));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await mfaSubscription.cancel();
      expect(mfaChallenges, 1);
      expect(utf8.decode(mfaOutput.takeBytes()), contains('mfa-ok'));

      final jumpEngine = DartSshEngine();
      addTearDown(jumpEngine.close);
      final jumpProfile = fixture.profileAt(fixture.jumpPort, 'Jump host');
      final jumpChannel = await jumpEngine.open(
        fixture.profile,
        fixture.credential(),
        jump: SshJumpConnection(
          profile: jumpProfile,
          credential: SshCredential(
            SshCredentialKind.password,
            fixture.password,
          ),
        ),
        verifyJumpHost: (pin) async {
          expect(pin.type, fixture.jumpHostKeyType);
          expect(pin.fingerprint, fixture.jumpHostKeyFingerprint);
          return true;
        },
        verifyHost: fixture.verify,
        isCurrent: () => true,
        answerChallenge: (_, _) async => null,
      );
      final jumpOutput = BytesBuilder(copy: false);
      final jumpSubscription = jumpChannel.stdout.listen(jumpOutput.add);
      jumpChannel.write(
        Uint8List.fromList(utf8.encode("printf 'jump-ok\\n'; exit\n")),
      );
      await jumpChannel.done.timeout(const Duration(seconds: 15));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await jumpSubscription.cancel();
      expect(utf8.decode(jumpOutput.takeBytes()), contains('jump-ok'));
    },
    skip: nativeSkip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'encrypted key, pinned host and PTY preserve UTF-8 and terminal size',
    () async {
      final engine = DartSshEngine();
      addTearDown(engine.close);
      final channel = await engine.open(
        fixture!.profile,
        fixture.credential(),
        verifyHost: fixture.verify,
        isCurrent: () => true,
        initialSize: const SshTerminalSize(columns: 101, rows: 37),
        answerChallenge: (_, _) async => null,
      );
      final output = BytesBuilder(copy: false);
      final errors = BytesBuilder(copy: false);
      final stdout = channel.stdout.listen(output.add);
      final stderr = channel.stderr.listen(errors.add);
      channel.resize(
        const SshTerminalSize(
          columns: 132,
          rows: 43,
          pixelWidth: 1584,
          pixelHeight: 1032,
        ),
      );
      channel.write(
        Uint8List.fromList(
          utf8.encode("printf 'Larenor İstanbul\\n'; stty size; exit\n"),
        ),
      );
      await channel.done.timeout(const Duration(seconds: 15));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await stdout.cancel();
      await stderr.cancel();
      final transcript = utf8.decode([
        ...output.takeBytes(),
        ...errors.takeBytes(),
      ], allowMalformed: false);
      expect(transcript, contains('Larenor İstanbul'));
      expect(transcript, contains(RegExp(r'43\s+132')));
    },
    skip: nativeSkip,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'SFTP list and transfers are bounded and cancellation closes ownership',
    () async {
      final engine = DartSftpEngine();
      addTearDown(engine.close);
      var current = true;
      final transport = await engine.open(
        fixture!.profile,
        fixture.credential(),
        verifyHost: fixture.verify,
        isCurrent: () => current,
      );
      final listing = await transport.list(
        fixture.root,
        maxEntries: 2,
        isCurrent: () => current,
      );
      expect(listing.entries, hasLength(2));
      expect(listing.truncated, isTrue);

      final hello = await transport.download(
        '${fixture.root}/hello.txt',
        maxBytes: 1024,
        isCurrent: () => current,
        onProgress: (_) {},
      );
      expect(utf8.decode(hello), 'Larenor SFTP fixture\n');

      final uploadPath = '${fixture.root}/upload-$pid.txt';
      final upload = Uint8List.fromList(utf8.encode('bounded upload'));
      await transport.upload(
        uploadPath,
        upload,
        maxBytes: 1024,
        isCurrent: () => current,
        onProgress: (_) {},
      );
      final roundTrip = await transport.download(
        uploadPath,
        maxBytes: 1024,
        isCurrent: () => current,
        onProgress: (_) {},
      );
      expect(roundTrip, upload);
      await expectLater(
        transport.upload(
          '${fixture.root}/too-large.txt',
          Uint8List(3),
          maxBytes: 2,
          isCurrent: () => current,
          onProgress: (_) {},
        ),
        throwsA(
          isA<SftpFailure>().having(
            (failure) => failure.code,
            'code',
            'file_too_large',
          ),
        ),
      );

      await expectLater(
        transport.upload(
          '${fixture.root}/cancelled-$pid.bin',
          Uint8List(1024 * 1024),
          maxBytes: 2 * 1024 * 1024,
          isCurrent: () => current,
          onProgress: (_) => current = false,
        ),
        throwsA(
          isA<SftpFailure>().having(
            (failure) => failure.code,
            'code',
            'retired',
          ),
        ),
      );
      expect(File('${fixture.root}/cancelled-$pid.bin').existsSync(), isFalse);

      current = true;
      await expectLater(
        transport.download(
          '${fixture.root}/large.bin',
          maxBytes: 2 * 1024 * 1024,
          isCurrent: () => current,
          onProgress: (_) => current = false,
        ),
        throwsA(
          isA<SftpFailure>().having(
            (failure) => failure.code,
            'code',
            'retired',
          ),
        ),
      );
      engine.close();
      await transport.done.timeout(const Duration(seconds: 5));
    },
    skip: nativeSkip,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'wrong host pin and closed local tunnel fail without retry or replay',
    () async {
      var socketAttempts = 0;
      SshHostPin? presentedPin;
      final expectedFingerprint = fixture!.hostKeyFingerprint;
      final changedFingerprint =
          '${expectedFingerprint.substring(0, expectedFingerprint.length - 1)}'
          '${expectedFingerprint.endsWith('A') ? 'B' : 'A'}';
      final rejected = DartSshEngine(
        connectSocket: (host, port) {
          socketAttempts++;
          return ssh.SSHSocket.connect(host, port);
        },
      );
      addTearDown(rejected.close);
      await expectLater(
        rejected.open(
          fixture.profile,
          fixture.credential(),
          verifyHost: (pin) async {
            presentedPin = pin;
            if (pin.type != fixture.hostKeyType ||
                pin.fingerprint != changedFingerprint) {
              throw const SshFailure('host_changed');
            }
            return true;
          },
          isCurrent: () => true,
          answerChallenge: (_, _) async => null,
        ),
        throwsA(
          isA<SshFailure>().having(
            (failure) => failure.code,
            'code',
            'host_changed',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(socketAttempts, 1);
      expect(presentedPin?.type, fixture.hostKeyType);
      expect(presentedPin?.fingerprint, fixture.hostKeyFingerprint);

      var tunnelCurrent = true;
      final tunnelEngine = DartSshTunnelEngine();
      addTearDown(tunnelEngine.close);
      final tunnel = SshTunnelProfile.parse(
        name: 'Fixture HTTP',
        localPort: '${fixture.tunnelPort}',
        targetHost: '127.0.0.1',
        targetPort: '${fixture.targetPort}',
      );
      final handle = await tunnelEngine.start(
        fixture.profile,
        fixture.credential(),
        tunnel,
        verifyHost: fixture.verify,
        isCurrent: () {
          if (!tunnelCurrent) throw StateError('retired fixture owner');
          return true;
        },
      );
      final socket = await Socket.connect(
        handle.localAddress,
        handle.localPort,
      );
      socket.write('GET / HTTP/1.0\r\nHost: fixture\r\n\r\n');
      final response = await utf8.decoder.bind(socket).join();
      expect(response, contains('200 OK'));
      expect(response, contains('Larenor tunnel fixture'));
      final retiredSocket = await Socket.connect(
        handle.localAddress,
        handle.localPort,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      tunnelCurrent = false;
      retiredSocket.write('GET / HTTP/1.0\r\nHost: fixture\r\n\r\n');
      await handle.done.timeout(const Duration(seconds: 5));
      await retiredSocket.close();
      await handle.done.timeout(const Duration(seconds: 5));
      await expectLater(
        Socket.connect(handle.localAddress, handle.localPort),
        throwsA(isA<SocketException>()),
      );
      expect(socketAttempts, 1);
    },
    skip: nativeSkip,
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test(
    'authority loss after local bind closes the unpublished listener',
    () async {
      var current = true;
      ServerSocket? bound;
      final engine = DartSshTunnelEngine(
        bindServer: (port) async {
          bound = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            port,
            shared: false,
          );
          current = false;
          return bound!;
        },
      );
      addTearDown(engine.close);
      final tunnel = SshTunnelProfile.parse(
        name: 'Retired before publish',
        localPort: '${fixture!.tunnelPort}',
        targetHost: '127.0.0.1',
        targetPort: '${fixture.targetPort}',
      );
      await expectLater(
        engine.start(
          fixture.profile,
          fixture.credential(),
          tunnel,
          verifyHost: fixture.verify,
          isCurrent: () => current,
        ),
        throwsA(
          isA<SshFailure>().having(
            (failure) => failure.code,
            'code',
            'retired',
          ),
        ),
      );
      expect(bound, isNotNull);
      final replacement = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        fixture.tunnelPort,
        shared: false,
      );
      await replacement.close();
    },
    skip: nativeSkip,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
