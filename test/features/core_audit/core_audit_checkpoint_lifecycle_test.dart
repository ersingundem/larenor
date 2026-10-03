import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/core_audit/data/core_audit_checkpoint_store.dart';
import 'package:larenor/features/core_audit/data/core_audit_controller.dart';
import 'package:larenor/features/core_audit/domain/core_audit_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final _now = DateTime.utc(2026, 10, 3, 12);
final _endpoint = ServerEndpoint('https://core-audit.test');
final _context = ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
});

ServerSession _session() => ServerSession(
  endpoint: _endpoint,
  accessToken: 'synthetic_access_token_00000000001',
  refreshToken: 'synthetic_refresh_token_0000000001',
  expiresAt: _now.add(const Duration(hours: 1)),
  user: const ServerUser(
    id: 'audit-admin',
    username: 'admin',
    role: ServerRole.admin,
    mustChangePassword: false,
  ),
  sessionFamilyId: 'c' * 32,
);

Map<String, Object?> _verificationJson({
  required String checkpoint,
  required int sequence,
  required bool compared,
}) => {
  'schemaVersion': 1,
  'scope': _context.toJson(),
  'chainId': 'd' * 32,
  'sequence': sequence,
  'headHash': sequence.toRadixString(16).padLeft(64, '0'),
  'checkpoint': checkpoint,
  'verified': true,
  'comparedCheckpoint': compared,
  'causalityVerified': false,
};

CoreAuditVerification _proof({
  required String checkpoint,
  required int sequence,
  required bool compared,
}) => CoreAuditVerification.fromJson(
  _verificationJson(
    checkpoint: checkpoint,
    sequence: sequence,
    compared: compared,
  ),
  expectedContext: _context,
  expectedComparison: compared,
);

final class _SessionStore implements ServerSessionPersistence {
  ServerSession? value;

  @override
  Future<ServerSession?> read() async => value;

  @override
  Future<void> write(ServerSession? session) async {
    value = session;
  }
}

final class _AuditApi extends LarenorServerApi {
  _AuditApi() : super(endpoint: _endpoint);

  final Completer<void> requestStarted = Completer<void>();
  Completer<Map<String, dynamic>?>? delayedAudit;
  Map<String, dynamic>? Function(String? checkpoint)? auditReply;
  int auditCalls = 0;

  @override
  Future<ServerSession> login({
    required String username,
    required String password,
    required String deviceName,
  }) async => _session();

  @override
  Future<ServerUser> me(String accessToken) async => _session().user;

  @override
  Future<ServerContext> context(String accessToken) async => _context;

  @override
  Future<void> logout(ServerSession session) async {}

  @override
  Future<Map<String, dynamic>?> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
    Map<String, String>? queryParameters,
    bool allowEmpty = false,
    LarenorTransferCancellation? cancellation,
  }) async {
    auditCalls++;
    if (!requestStarted.isCompleted) requestStarted.complete();
    final delayed = delayedAudit;
    if (delayed != null) return delayed.future;
    return auditReply?.call(queryParameters?['checkpoint']);
  }

  @override
  void close() {}
}

final class _Backend implements CoreAuditCheckpointBackend {
  String? value;
  int reads = 0, writes = 0;
  bool readFails = false;
  bool throwBeforeWrite = false;
  bool throwAfterWrite = false;

  @override
  Future<String?> read(String key) async {
    reads++;
    if (readFails) throw StateError('private read failure');
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    if (throwBeforeWrite) throw StateError('private write failure');
    this.value = value;
    if (throwAfterWrite) throw StateError('private uncertain write');
  }
}

Matcher _checkpointCode(String code) => isA<CoreAuditCheckpointException>()
    .having((error) => error.code, 'code', code);

Future<ServerAccountController> _signedIn(_AuditApi api) async {
  final account = ServerAccountController(
    store: _SessionStore(),
    apiFactory: (_) => api,
    clock: () => _now,
  );
  await account.signIn(
    baseUrl: _endpoint.baseUrl,
    username: 'admin',
    password: 'Synthetic password 2026',
    deviceName: 'Audit test',
  );
  expect(account.failure, isNull);
  return account;
}

Future<void> _flush() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'late audit completion cannot republish after account retirement',
    () async {
      final api = _AuditApi()
        ..delayedAudit = Completer<Map<String, dynamic>?>();
      final account = await _signedIn(api);
      addTearDown(account.dispose);
      final controller = CoreAuditController(
        account,
        CoreAuditCheckpointStore(backend: _Backend()),
      );
      addTearDown(controller.dispose);

      await api.requestStarted.future;
      await account.signOut();
      api.delayedAudit!.complete({
        'verification': _verificationJson(
          checkpoint: 'late-checkpoint',
          sequence: 1,
          compared: false,
        ),
      });
      await _flush();

      expect(controller.available, isFalse);
      expect(controller.busy, isFalse);
      expect(controller.loaded, isFalse);
      expect(controller.verification, isNull);
      expect(controller.trustedCheckpoint, isNull);
      expect(controller.failure, isNull);
      expect(api.auditCalls, 1);
    },
  );

  test('disposed route ignores a late audit response', () async {
    final api = _AuditApi()..delayedAudit = Completer<Map<String, dynamic>?>();
    final account = await _signedIn(api);
    addTearDown(account.dispose);
    final controller = CoreAuditController(
      account,
      CoreAuditCheckpointStore(backend: _Backend()),
    );
    var notifications = 0;
    controller.addListener(() => notifications++);

    await api.requestStarted.future;
    controller.dispose();
    final atDispose = notifications;
    api.delayedAudit!.complete({
      'verification': _verificationJson(
        checkpoint: 'late-checkpoint',
        sequence: 1,
        compared: false,
      ),
    });
    await _flush();

    expect(notifications, atDispose);
    expect(controller.verification, isNull);
    expect(controller.trustedCheckpoint, isNull);
  });

  test(
    'malformed, oversize and failed reads preserve retained bytes',
    () async {
      final backend = _Backend();
      final store = CoreAuditCheckpointStore(backend: backend);
      final malformed = <String>[
        '{',
        'x' * 4097,
        jsonEncode({
          'version': 1,
          'scope': _context.toJson(),
          'chainId': 'd' * 32,
          'sequence': 1,
          'headHash': 'e' * 64,
          'checkpoint': 'retained',
          'pinnedAt': _now.toIso8601String(),
          'revision': 1,
          'private': true,
        }),
      ];
      for (final raw in malformed) {
        backend.value = raw;
        final writes = backend.writes;
        await expectLater(
          store.read(_context, isCurrent: () => true),
          throwsA(_checkpointCode('invalid_record')),
        );
        expect(backend.value, raw);
        expect(backend.writes, writes);
      }
      backend.value = 'retained-unreadable-bytes';
      backend.readFails = true;
      await expectLater(
        store.read(_context, isCurrent: () => true),
        throwsA(_checkpointCode('read_failed')),
      );
      expect(backend.value, 'retained-unreadable-bytes');
    },
  );

  test(
    'failed and uncertain rotation preserve a trusted readback boundary',
    () async {
      final backend = _Backend();
      final store = CoreAuditCheckpointStore(
        backend: backend,
        clock: () => _now,
      );
      final before = await store.pin(
        _context,
        _proof(checkpoint: 'checkpoint-one', sequence: 1, compared: false),
        isCurrent: () => true,
      );
      final beforeBytes = backend.value;
      final next = _proof(
        checkpoint: 'checkpoint-two',
        sequence: 2,
        compared: true,
      );

      backend.throwBeforeWrite = true;
      await expectLater(
        store.rotate(_context, before, next, isCurrent: () => true),
        throwsA(_checkpointCode('write_failed')),
      );
      expect(backend.value, beforeBytes);
      expect(await store.read(_context, isCurrent: () => true), before);

      backend.throwBeforeWrite = false;
      backend.throwAfterWrite = true;
      await expectLater(
        store.rotate(_context, before, next, isCurrent: () => true),
        throwsA(_checkpointCode('write_failed')),
      );
      final reconciled = await store.read(_context, isCurrent: () => true);
      expect(reconciled!.revision, 2);
      expect(reconciled.checkpoint, 'checkpoint-two');
      expect(before.revision, 1);
      expect(before.checkpoint, 'checkpoint-one');
    },
  );

  test(
    'conflict and maximum revision never replace the retained record',
    () async {
      final backend = _Backend();
      final store = CoreAuditCheckpointStore(
        backend: backend,
        clock: () => _now,
      );
      final first = await store.pin(
        _context,
        _proof(checkpoint: 'checkpoint-one', sequence: 1, compared: false),
        isCurrent: () => true,
      );
      final second = await store.rotate(
        _context,
        first,
        _proof(checkpoint: 'checkpoint-two', sequence: 2, compared: true),
        isCurrent: () => true,
      );
      final secondBytes = backend.value;
      await expectLater(
        store.rotate(
          _context,
          first,
          _proof(checkpoint: 'checkpoint-three', sequence: 3, compared: true),
          isCurrent: () => true,
        ),
        throwsA(_checkpointCode('conflict')),
      );
      expect(backend.value, secondBytes);
      expect(await store.read(_context, isCurrent: () => true), second);

      final maximum = jsonDecode(secondBytes!) as Map<String, dynamic>;
      maximum['revision'] = 0x1fffffffffffff;
      backend.value = jsonEncode(maximum);
      final maximumRecord = await store.read(_context, isCurrent: () => true);
      final maximumBytes = backend.value;
      await expectLater(
        store.rotate(
          _context,
          maximumRecord!,
          _proof(checkpoint: 'checkpoint-three', sequence: 3, compared: true),
          isCurrent: () => true,
        ),
        throwsA(_checkpointCode('limit')),
      );
      expect(backend.value, maximumBytes);
      expect(await store.read(_context, isCurrent: () => true), maximumRecord);
    },
  );
}
