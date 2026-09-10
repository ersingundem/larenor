import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/ssh/ssh_engine.dart';
import 'package:larenor/features/remote_access/ssh/ssh_security_store.dart';
import 'package:larenor/features/remote_access/ssh/ssh_session_controller.dart';

import '../remote_profiles_test.dart' show profile;

const hostPin = SshHostPin(
  'ssh-ed25519',
  'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);

class Security extends SshSecurityStore {
  SshHostPin? pin;
  bool valid = true;
  int checks = 0;
  Completer<void>? readGate;
  @override
  Future<void> checkProfile(
    RemoteProfile p, {
    required bool Function() isCurrent,
  }) async {
    checks++;
    if (!valid || !isCurrent()) throw const SshFailure('profile_changed');
  }

  @override
  Future<SshCredential?> readCredential(
    RemoteProfile p, {
    required bool Function() isCurrent,
  }) async {
    await readGate?.future;
    return const SshCredential(SshCredentialKind.password, 'test-secret');
  }

  @override
  Future<SshHostPin?> readPin(
    RemoteProfile p, {
    required bool Function() isCurrent,
  }) async => pin;
  @override
  Future<void> trust(
    RemoteProfile p,
    SshHostPin value, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const SshFailure('retired');
    pin = value;
  }
}

class JumpSecurity extends SshSecurityStore {
  final credentials = <String, SshCredential>{};
  final pins = <String, SshHostPin>{};
  @override
  Future<void> checkProfile(
    RemoteProfile p, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const SshFailure('profile_changed');
  }

  @override
  Future<SshCredential?> readCredential(
    RemoteProfile p, {
    required bool Function() isCurrent,
  }) async => credentials[p.id];

  @override
  Future<SshHostPin?> readPin(
    RemoteProfile p, {
    required bool Function() isCurrent,
  }) async => pins[p.id];

  @override
  Future<void> trust(
    RemoteProfile p,
    SshHostPin value, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const SshFailure('retired');
    pins[p.id] = value;
  }
}

class Channel extends SshChannel {
  final out = StreamController<List<int>>(),
      err = StreamController<List<int>>();
  final finished = Completer<void>();
  final writes = <List<int>>[];
  final resizes = <SshTerminalSize>[];
  bool closed = false;
  @override
  Stream<List<int>> get stdout => out.stream;
  @override
  Stream<List<int>> get stderr => err.stream;
  @override
  Future<void> get done => finished.future;
  @override
  void write(Uint8List data) {
    writes.add(List.of(data));
  }

  @override
  void resize(SshTerminalSize size) {
    resizes.add(size);
  }

  @override
  void close() {
    closed = true;
    if (!finished.isCompleted) finished.complete();
    out.close();
    err.close();
  }
}

class Engine extends SshEngine {
  final Channel channel = Channel();
  bool closed = false;
  int opens = 0;
  Completer<void>? gate;
  SshHostPin presented = hostPin;
  SshJumpConnection? receivedJump;
  SshAuthChallenge? challenge;
  SshHop challengeHop = SshHop.target;
  @override
  Future<SshChannel> open(
    RemoteProfile p,
    SshCredential c, {
    required Future<bool> Function(SshHostPin) verifyHost,
    required bool Function() isCurrent,
    SshTerminalSize initialSize = SshTerminalSize.standard,
    SshJumpConnection? jump,
    required Future<List<String>?> Function(SshHop, SshAuthChallenge)
    answerChallenge,
    Future<bool> Function(SshHostPin)? verifyJumpHost,
  }) async {
    opens++;
    receivedJump = jump;
    await gate?.future;
    if (jump != null &&
        !await verifyJumpHost!(
          const SshHostPin(
            'ssh-ed25519',
            'SHA256:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC',
          ),
        )) {
      throw const SshFailure('jump_host_rejected');
    }
    if (!await verifyHost(presented)) throw const SshFailure('host_rejected');
    if (challenge case final value?) {
      final answers = await answerChallenge(challengeHop, value);
      if (answers == null) throw const SshFailure('challenge_rejected');
    }
    if (!isCurrent()) throw const SshFailure('retired');
    return channel;
  }

  @override
  void close() {
    closed = true;
    channel.close();
  }
}

Future<void> tick() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Security store;
  late Engine engine;
  late SshSessionController c;
  bool current = true;
  setUp(() {
    store = Security();
    engine = Engine();
    current = true;
    c = SshSessionController(
      profile: profile(),
      store: store,
      engineFactory: () => engine,
      isCurrent: () => current,
      connectTimeout: const Duration(milliseconds: 150),
    );
  });
  tearDown(() => c.dispose());
  test(
    'unknown host waits for explicit trust then opens with zero command replay',
    () async {
      final opening = c.connect();
      await tick();
      expect(c.phase, SshSessionPhase.hostKey);
      expect(engine.channel.writes, isEmpty);
      await c.trustHost();
      await opening;
      expect(c.phase, SshSessionPhase.connected);
      expect(store.pin!.fingerprint, hostPin.fingerprint);
      expect(engine.channel.writes, isEmpty);
    },
  );
  test(
    'changed pinned key stops before channel input and never replaces pin',
    () async {
      store.pin = const SshHostPin(
        'ssh-rsa',
        'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
      );
      await c.connect();
      expect(c.error, 'host_changed');
      expect(c.phase, SshSessionPhase.failed);
      expect(store.pin!.type, 'ssh-rsa');
      expect(engine.closed, isTrue);
      expect(engine.channel.writes, isEmpty);
    },
  );
  test(
    'cancel unknown host closes engine and held trust cannot persist',
    () async {
      final opening = c.connect();
      await tick();
      c.cancel();
      await c.trustHost();
      await opening;
      expect(store.pin, isNull);
      expect(c.phase, SshSessionPhase.closed);
      expect(engine.closed, isTrue);
    },
  );
  test('cancel while credential read prevents engine creation', () async {
    store.readGate = Completer<void>();
    final opening = c.connect();
    await tick();
    c.cancel();
    store.readGate!.complete();
    await opening;
    expect(engine.opens, 0);
    expect(c.phase, SshSessionPhase.closed);
  });
  test(
    'connection deadline includes trust prompt and closes resources',
    () async {
      await c.connect();
      expect(c.error, 'timed_out');
      expect(engine.closed, isTrue);
      expect(store.pin, isNull);
    },
  );
  test(
    'retired operation never revives when owner becomes current again',
    () async {
      store.readGate = Completer<void>();
      final opening = c.connect();
      await tick();
      current = false;
      c.retire();
      current = true;
      store.readGate!.complete();
      await opening;
      await c.connect();
      expect(engine.opens, 0);
      expect(c.transcript, isEmpty);
    },
  );
  test(
    'streaming UTF8 both streams bounded history, one explicit input line',
    () async {
      store.pin = hostPin;
      await c.connect();
      final bytes = utf8.encode('Türkçe');
      engine.channel.out.add(bytes.sublist(0, 2));
      engine.channel.out.add(bytes.sublist(2));
      await tick();
      engine.channel.err.add(utf8.encode(' error'));
      await tick();
      expect(c.transcript, contains('Türkçe'));
      expect(c.transcript, contains('error'));
      engine.channel.out.add(utf8.encode('x' * 70000));
      await tick();
      expect(c.transcript.length, lessThanOrEqualTo(65536));
      await c.sendLine('echo İstanbul, çığ öşü');
      expect(
        utf8.decode(engine.channel.writes.single),
        'echo İstanbul, çığ öşü\n',
      );
    },
  );
  test(
    'PTY size is bounded, deduplicated and sent only while connected',
    () async {
      store.pin = hostPin;
      c.resizeTerminal(const SshTerminalSize(columns: 132, rows: 40));
      expect(engine.channel.resizes, isEmpty);
      await c.connect();
      expect(engine.channel.resizes, isEmpty);
      c.resizeTerminal(const SshTerminalSize(columns: 140, rows: 42));
      c.resizeTerminal(const SshTerminalSize(columns: 140, rows: 42));
      expect(engine.channel.resizes, [
        const SshTerminalSize(columns: 140, rows: 42),
      ]);
      expect(
        () => c.resizeTerminal(SshTerminalSize(columns: 10, rows: 2)),
        throwsA(isA<SshFailure>()),
      );
      c.cancel();
      c.resizeTerminal(const SshTerminalSize(columns: 100, rows: 30));
      expect(engine.channel.resizes, hasLength(1));
    },
  );
  test('multiline, oversized and control input never sends', () async {
    store.pin = hostPin;
    await c.connect();
    for (final line in ['one\ntwo', 'bad\u001b', 'x' * 4097]) {
      await c.sendLine(line);
    }
    expect(engine.channel.writes, isEmpty);
  });
  test(
    'profile replacement before send retires terminal and clears output',
    () async {
      store.pin = hostPin;
      await c.connect();
      engine.channel.out.add(utf8.encode('private output'));
      await tick();
      store.valid = false;
      await c.sendLine('never');
      expect(engine.channel.writes, isEmpty);
      expect(engine.closed, isTrue);
      expect(c.transcript, isEmpty);
    },
  );
  test('loss and late stream/error never publish into retired view', () async {
    store.pin = hostPin;
    await c.connect();
    current = false;
    engine.channel.out.add(utf8.encode('late'));
    await tick();
    expect(c.transcript, isEmpty);
    expect(engine.closed, isTrue);
  });
  test(
    'normal completion preserves final queued output after channel done',
    () async {
      store.pin = hostPin;
      await c.connect();
      engine.channel.finished.complete();
      await tick();
      engine.channel.out.add(utf8.encode('final output'));
      await engine.channel.out.close();
      await engine.channel.err.close();
      await tick();
      expect(c.transcript, 'final output');
      expect(c.phase, SshSessionPhase.closed);
    },
  );
  test('peer close is not success and never auto-reconnects', () async {
    store.pin = hostPin;
    await c.connect();
    engine.channel.close();
    await tick();
    expect(c.phase, SshSessionPhase.closed);
    expect(engine.opens, 1);
  });
  test(
    'late open after cancel closes channel without becoming connected',
    () async {
      store.pin = hostPin;
      engine.gate = Completer<void>();
      final opening = c.connect();
      await tick();
      c.cancel();
      engine.gate!.complete();
      await opening;
      expect(engine.closed, isTrue);
      expect(c.phase, SshSessionPhase.closed);
    },
  );
  test(
    'MFA answer is one-shot, secret-free state and stale submit is rejected',
    () async {
      store.pin = hostPin;
      engine.challenge = const SshAuthChallenge(
        name: 'Second factor',
        instruction: 'Enter current code',
        prompts: [SshAuthPrompt(text: 'Code:', echo: false)],
      );
      final opening = c.connect();
      await tick();
      expect(c.phase, SshSessionPhase.challenge);
      expect(c.pendingChallenge!.prompts.single.text, 'Code:');
      expect(c.toString(), isNot(contains('654321')));
      await c.answerChallenge(['654321']);
      await opening;
      expect(c.phase, SshSessionPhase.connected);
      expect(c.pendingChallenge, isNull);
      c.cancel();
      await c.answerChallenge(['stale']);
      expect(engine.channel.writes, isEmpty);
    },
  );
  test('single jump hop keeps credentials and host pins separate', () async {
    final target = profile();
    final jump = RemoteProfile(
      id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      name: 'Jump',
      protocol: RemoteProtocol.ssh,
      host: 'jump.example',
      port: 2222,
      username: 'bastion',
    );
    final security = JumpSecurity()
      ..credentials[target.id] = const SshCredential(
        SshCredentialKind.password,
        'target-secret',
      )
      ..credentials[jump.id] = const SshCredential(
        SshCredentialKind.password,
        'jump-secret',
      )
      ..pins[target.id] = hostPin
      ..pins[jump.id] = const SshHostPin(
        'ssh-ed25519',
        'SHA256:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC',
      );
    final routedEngine = Engine();
    final routed = SshSessionController(
      profile: target,
      jumpProfile: jump,
      store: security,
      engineFactory: () => routedEngine,
      isCurrent: () => true,
    );
    addTearDown(routed.dispose);
    await routed.connect();
    expect(routed.phase, SshSessionPhase.connected);
    expect(routedEngine.receivedJump!.profile.id, jump.id);
    expect(routedEngine.receivedJump!.credential.secret, 'jump-secret');
    expect(routedEngine.channel.writes, isEmpty);
    expect(security.pins.keys, containsAll([target.id, jump.id]));
  });
}
