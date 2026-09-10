import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/ssh/sftp_controller.dart';
import 'package:larenor/features/remote_access/ssh/sftp_engine.dart';
import 'package:larenor/features/remote_access/ssh/sftp_file_access.dart';
import 'package:larenor/features/remote_access/ssh/sftp_models.dart';
import 'package:larenor/features/remote_access/ssh/ssh_security_store.dart';

import '../remote_profiles_test.dart' show profile;
import 'ssh_session_controller_test.dart' show Security, hostPin;

class FakeSftpTransport implements SftpTransport {
  final doneCompleter = Completer<void>();
  List<SftpEntry> listing = const [];
  final uploaded = <String, Uint8List>{};
  final reads = <String>[];
  Completer<void>? operationGate;
  int listCalls = 0;
  bool closed = false;

  @override
  Future<void> get done => doneCompleter.future;

  @override
  Future<SftpListing> list(
    String path, {
    required int maxEntries,
    required bool Function() isCurrent,
  }) async {
    listCalls++;
    await operationGate?.future;
    if (!isCurrent()) throw const SftpFailure('retired');
    return SftpListing(
      listing.take(maxEntries).toList(),
      truncated: listing.length > maxEntries,
    );
  }

  @override
  Future<Uint8List> download(
    String path, {
    required int maxBytes,
    required bool Function() isCurrent,
    required void Function(int transferred) onProgress,
  }) async {
    reads.add(path);
    await operationGate?.future;
    if (!isCurrent()) throw const SftpFailure('retired');
    onProgress(3);
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<void> upload(
    String path,
    Uint8List bytes, {
    required int maxBytes,
    required bool Function() isCurrent,
    required void Function(int transferred) onProgress,
  }) async {
    await operationGate?.future;
    if (!isCurrent()) throw const SftpFailure('retired');
    uploaded[path] = Uint8List.fromList(bytes);
    onProgress(bytes.length);
  }

  @override
  void close() {
    closed = true;
    if (!doneCompleter.isCompleted) doneCompleter.complete();
  }
}

class FakeSftpEngine implements SftpEngine {
  FakeSftpEngine(this.transport);
  final FakeSftpTransport transport;
  int opens = 0;
  bool closed = false;
  @override
  Future<SftpTransport> open(
    RemoteProfile profile,
    SshCredential credential, {
    required Future<bool> Function(SshHostPin pin) verifyHost,
    required bool Function() isCurrent,
  }) async {
    opens++;
    if (!await verifyHost(hostPin)) throw const SftpFailure('host_rejected');
    if (!isCurrent()) throw const SftpFailure('retired');
    return transport;
  }

  @override
  void close() {
    closed = true;
    transport.close();
  }
}

void main() {
  late Security store;
  late FakeSftpTransport transport;
  late FakeSftpEngine engine;
  late SftpController controller;
  late List<String> saved;
  bool current = true;

  setUp(() {
    store = Security();
    transport = FakeSftpTransport();
    engine = FakeSftpEngine(transport);
    saved = [];
    current = true;
    controller = SftpController(
      profile: profile(),
      store: store,
      engineFactory: () => engine,
      fileAccess: SftpFileAccess(
        pickFile: () async => const SftpUpload('new.txt', [7, 8]),
        saveFile: (name, bytes) async {
          saved.add('$name:${bytes.length}');
          return Uri.parse('content://downloads/$name');
        },
      ),
      isCurrent: () => current,
    );
  });
  tearDown(() => controller.dispose());

  Future<void> connect() async {
    store.pin = hostPin;
    await controller.connect();
    expect(controller.phase, SftpPhase.ready);
  }

  test(
    'reuses saved credential and host pin without listing or retry',
    () async {
      await connect();
      expect(engine.opens, 1);
      expect(transport.listCalls, 0);
      expect(controller.path, '/');
    },
  );

  test(
    'unknown key requires explicit trust before SFTP becomes ready',
    () async {
      final opening = controller.connect();
      await Future<void>.delayed(Duration.zero);
      expect(controller.phase, SftpPhase.hostKey);
      expect(controller.pendingPin, hostPin);
      await controller.trustHost();
      await opening;
      expect(store.pin, hostPin);
      expect(controller.phase, SftpPhase.ready);
    },
  );

  test(
    'bounded listing normalizes path, sorts folders and reports truncation',
    () async {
      await connect();
      transport.listing = [
        const SftpEntry.file('z.txt', '/srv/z.txt', size: 9),
        const SftpEntry.directory('Albums', '/srv/Albums'),
        ...List.generate(
          sftpMaxEntries,
          (i) => SftpEntry.file('f$i', '/srv/f$i'),
        ),
      ];
      await controller.openDirectory('/srv//./');
      expect(controller.path, '/srv');
      expect(controller.entries, hasLength(sftpMaxEntries));
      expect(controller.entries.first.name, 'Albums');
      expect(controller.truncated, isTrue);
      expect(transport.listCalls, 1);
    },
  );

  test(
    'download and upload require explicit calls and use normalized paths',
    () async {
      await connect();
      const file = SftpEntry.file('movie.mkv', '/media/movie.mkv', size: 3);
      await controller.download(file);
      expect(transport.reads, ['/media/movie.mkv']);
      expect(saved, ['movie.mkv:3']);
      await controller.openDirectory('/media');
      await controller.pickAndUpload();
      expect(transport.uploaded['/media/new.txt'], [7, 8]);
      expect(engine.opens, 1);
    },
  );

  test('cancel closes active transfer and late completion cannot publish or replay', () async {
    await connect();
    transport.operationGate = Completer<void>();
    final operation = controller.openDirectory('/held');
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, SftpPhase.listing);
    controller.cancel();
    transport.operationGate!.complete();
    await operation;
    expect(engine.closed, isTrue);
    expect(controller.phase, SftpPhase.closed);
    expect(controller.entries, isEmpty);
    expect(engine.opens, 1);
    await controller.connect();
    expect(engine.opens, 2);
  });

  test('owner retirement closes session and wipes downloaded bytes', () async {
    await connect();
    current = false;
    controller.retire();
    expect(engine.closed, isTrue);
    expect(controller.phase, SftpPhase.closed);
    expect(controller.progress, 0);
  });
}
