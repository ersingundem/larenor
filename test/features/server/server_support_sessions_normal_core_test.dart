import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/support_sessions/data/server_support_sessions_controller.dart';
import 'package:larenor/features/server/support_sessions/domain/server_support_session_models.dart';

const _password = 'Synthetic new password 2026';
const _temporaryPassword = 'Synthetic support admin password 2026';
const _primarySupporter = 'f14.primary';
const _uncertainSupporter = 'f14.uncertain';

final class _FileStore implements ServerSessionPersistence {
  _FileStore(this.file, this.baseUrl);

  final File file;
  final String baseUrl;

  @override
  Future<ServerSession?> read() async {
    if (!file.existsSync() || file.lengthSync() == 0) return null;
    final value = Map<String, Object?>.from(
      jsonDecode(await file.readAsString()) as Map,
    );
    value['baseUrl'] = baseUrl;
    return ServerSession.decodeStorage(jsonEncode(value));
  }

  @override
  Future<void> write(ServerSession? session) async {
    if (session == null) {
      await file.writeAsString('', flush: true);
      return;
    }
    await file.writeAsString(session.encodeStorage(), flush: true);
  }
}

final class _MemoryStore implements ServerSessionPersistence {
  ServerSession? value;

  @override
  Future<ServerSession?> read() async => value;

  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _WireStats {
  int supportCreates = 0;
  bool droppedUncertainResponse = false;
}

final class _ObservedApi extends LarenorServerApi {
  _ObservedApi({required super.endpoint, required this.stats});

  final _WireStats stats;

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
    final create =
        method == 'POST' &&
        RegExp(r'^/support-sessions/[0-9a-f]{32}/[0-9a-f]{32}$').hasMatch(path);
    if (create) stats.supportCreates++;
    final result = await super.request(
      method,
      path,
      token: token,
      body: body,
      queryParameters: queryParameters,
      allowEmpty: allowEmpty,
      cancellation: cancellation,
    );
    if (create &&
        body?['supporterId'] == _uncertainSupporter &&
        !stats.droppedUncertainResponse) {
      stats.droppedUncertainResponse = true;
      throw const LarenorServerException('connection_failed');
    }
    return result;
  }
}

Future<void> _signIn(
  ServerAccountController account,
  String baseUrl, {
  String username = 'admin',
  String password = _password,
  String deviceName = 'F14 acceptance',
}) async {
  await account.signIn(
    baseUrl: baseUrl,
    username: username,
    password: password,
    deviceName: deviceName,
  );
  expect(account.failure, isNull);
  expect(account.session, isNotNull);
}

Future<Map<String, Object?>> _supportAccess({
  required String coreUrl,
  required ServerContext context,
  required String token,
}) async {
  final client = HttpClient();
  try {
    final base = Uri.parse(coreUrl);
    final uri = base.replace(
      path:
          '/api/v1/support-sessions/${context.coreId}/${context.homeId}/access',
    );
    final request = await client.postUrl(uri);
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..set('X-Larenor-Supporter', _primarySupporter);
    request.write(
      jsonEncode({'schemaVersion': 1, 'permission': supportCoreHealth}),
    );
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > 64 * 1024) {
        throw const LarenorServerException('invalid_response');
      }
    }
    final result = jsonDecode(utf8.decode(bytes));
    if (result is! Map ||
        result.length != 4 ||
        result['schemaVersion'] != 1 ||
        result['permission'] != supportCoreHealth ||
        result['result'] is! Map ||
        result['logPolicy'] is! Map) {
      throw const LarenorServerException('invalid_response');
    }
    final payload = Map<String, Object?>.from(result['result'] as Map);
    expect(payload, {
      'status': 'ready',
      'coreId': context.coreId,
      'homeId': context.homeId,
      'secretsIncluded': false,
      'remoteShellAvailable': false,
    });
    return payload;
  } finally {
    client.close(force: true);
  }
}

Future<void> _proveRoleDrift({
  required ServerAccountController owner,
  required String coreUrl,
}) async {
  late String delegatedId;
  await owner.withSession((api, session) async {
    final created = await api.request(
      'POST',
      '/admin/users',
      token: session.accessToken,
      body: {
        'username': 'f14-delegated',
        'role': 'admin',
        'initialPassword': _temporaryPassword,
      },
    );
    delegatedId = ((created?['user'] as Map)['id']) as String;
  });

  final delegated = ServerAccountController(store: _MemoryStore());
  ServerSupportSessionsController? controller;
  try {
    await _signIn(
      delegated,
      coreUrl,
      username: 'f14-delegated',
      password: _temporaryPassword,
      deviceName: 'F14 delegated acceptance',
    );
    await delegated.changePassword(
      currentPassword: _temporaryPassword,
      newPassword: _password,
    );
    expect(delegated.failure, isNull);
    controller = ServerSupportSessionsController(delegated);
    await controller.load(() => true);
    expect(controller.failure, isNull);

    await owner.withSession((api, session) async {
      await api.request(
        'PATCH',
        '/admin/users/$delegatedId',
        token: session.accessToken,
        body: {'expectedRevision': 2, 'role': 'member'},
      );
    });
    await controller.create(
      supporterId: 'f14.role-drift',
      supporterName: 'Stale role must not issue',
      permissions: const [supportCoreHealth],
      current: () => true,
    );
    expect(delegated.session, isNull);
    expect(controller.sessions, isEmpty);
    expect(controller.takeIssuedToken(), isNull);
  } finally {
    controller?.dispose();
    delegated.dispose();
  }
}

Future<void> _proveContextDrift({
  required String coreUrl,
  required String alternateCoreUrl,
}) async {
  final account = ServerAccountController(store: _MemoryStore());
  ServerSupportSessionsController? stale;
  try {
    await _signIn(account, coreUrl, deviceName: 'F14 context source');
    stale = ServerSupportSessionsController(account);
    await stale.load(() => true);
    expect(stale.failure, isNull);
    await account.signOut();
    await _signIn(
      account,
      alternateCoreUrl,
      deviceName: 'F14 context replacement',
    );
    await stale.create(
      supporterId: 'f14.context-drift',
      supporterName: 'Stale home must not issue',
      permissions: const [supportCoreHealth],
      current: () => true,
    );
    expect(stale.sessions, isEmpty);
    expect(stale.takeIssuedToken(), isNull);

    final current = ServerSupportSessionsController(account);
    try {
      await current.load(() => true);
      expect(current.failure, isNull);
      expect(current.sessions, isEmpty);
    } finally {
      current.dispose();
    }
  } finally {
    stale?.dispose();
    account.dispose();
  }
}

void main() {
  final phase = Platform.environment['LARENOR_F14_PHASE'];
  final coreUrl = Platform.environment['LARENOR_F14_CORE_URL'];
  final sessionFile = Platform.environment['LARENOR_F14_SESSION_FILE'];
  final checkpointFile = Platform.environment['LARENOR_F14_CHECKPOINT_FILE'];
  final fixtureReady =
      (phase == 'prepare' || phase == 'restart') &&
      coreUrl != null &&
      sessionFile != null &&
      checkpointFile != null;
  setUpAll(() => HttpOverrides.global = null);

  test(
    'real Client reconciles one-view support authority across restart',
    () async {
      final stats = _WireStats();
      final account = ServerAccountController(
        store: _FileStore(File(sessionFile!), coreUrl!),
        apiFactory: (endpoint) =>
            _ObservedApi(endpoint: endpoint, stats: stats),
      );
      addTearDown(account.dispose);

      if (phase == 'prepare') {
        await _signIn(account, coreUrl);
      } else {
        await account.initialize();
        expect(account.failure, isNull);
        expect(account.session, isNotNull);
      }
      final controller = ServerSupportSessionsController(account);
      addTearDown(controller.dispose);
      await controller.load(() => true);
      expect(controller.failure, isNull);

      if (phase == 'prepare') {
        expect(controller.sessions, isEmpty);
        await controller.create(
          supporterId: _primarySupporter,
          supporterName: 'Owned F14 support client',
          permissions: const [supportActivityRead, supportCoreHealth],
          current: () => true,
        );
        expect(controller.failure, isNull);
        expect(controller.sessions, hasLength(1));
        final primary = controller.sessions.single;
        final issued = controller.takeIssuedToken();
        expect(issued, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        expect(controller.takeIssuedToken(), isNull);
        await _supportAccess(
          coreUrl: coreUrl,
          context: account.session!.context!,
          token: issued!,
        );
        await controller.loadDetail(primary, () => true);
        expect(controller.failure, isNull);
        expect(controller.detail?.session.id, primary.id);
        expect(controller.detail?.activity, hasLength(1));
        expect(
          controller.detail?.activity.single.permission,
          supportCoreHealth,
        );
        expect(controller.detail?.activity.single.outcome, 'allowed');

        await controller.create(
          supporterId: _uncertainSupporter,
          supporterName: 'Lost response support client',
          permissions: const [supportCoreHealth],
          current: () => true,
        );
        expect(controller.failure, 'connection_failed');
        expect(controller.needsRefresh, isTrue);
        expect(controller.takeIssuedToken(), isNull);
        expect(stats.supportCreates, 2);
        await controller.refresh(() => true);
        expect(controller.failure, isNull);
        expect(controller.needsRefresh, isFalse);
        expect(controller.sessions, hasLength(2));
        expect(stats.supportCreates, 2);

        final before = List<ServerSupportSession>.of(controller.sessions);
        await controller.create(
          supporterId: 'f14.hidden-route',
          supporterName: 'Hidden route must not issue',
          permissions: const [supportCoreHealth],
          current: () => false,
        );
        expect(controller.sessions, before);
        expect(controller.takeIssuedToken(), isNull);
        expect(stats.supportCreates, 2);

        await File(checkpointFile!).writeAsString(
          jsonEncode({'schemaVersion': 1, 'primarySessionId': primary.id}),
          flush: true,
        );
        await _proveRoleDrift(owner: account, coreUrl: coreUrl);
        await _proveContextDrift(
          coreUrl: coreUrl,
          alternateCoreUrl:
              Platform.environment['LARENOR_F14_ALTERNATE_CORE_URL']!,
        );
      } else {
        final checkpoint = Map<String, Object?>.from(
          jsonDecode(await File(checkpointFile!).readAsString()) as Map,
        );
        expect(checkpoint.keys.toSet(), {'schemaVersion', 'primarySessionId'});
        expect(checkpoint['schemaVersion'], 1);
        expect(controller.sessions, hasLength(2));
        final primary = controller.sessions.singleWhere(
          (value) => value.id == checkpoint['primarySessionId'],
        );
        await controller.loadDetail(primary, () => true);
        expect(controller.failure, isNull);
        expect(controller.detail?.activity, hasLength(1));
        expect(
          controller.detail?.activity.single.permission,
          supportCoreHealth,
        );
        for (final session in List<ServerSupportSession>.of(
          controller.sessions,
        )) {
          await controller.revoke(session, () => true);
          expect(controller.failure, isNull);
          expect(
            controller.sessions
                .singleWhere((value) => value.id == session.id)
                .state,
            'revoked',
          );
          expect(controller.takeIssuedToken(), isNull);
        }
        expect(controller.sessions.every((value) => !value.active), isTrue);
      }
    },
    skip: !fixtureReady
        ? 'Run with server/tests/support/f14_flutter_acceptance.py'
        : false,
  );
}
