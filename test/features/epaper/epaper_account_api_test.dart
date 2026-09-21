import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/epaper/data/epaper_account_api.dart';
import 'package:larenor/features/epaper/domain/epaper_management_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _Store implements ServerSessionPersistence {
  _Store(this.value);
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _AuthApi extends LarenorServerApi {
  _AuthApi(this.value)
    : super(
        endpoint: value.endpoint,
        client: MockClient((_) async => http.Response('{}', 500)),
      );
  final ServerSession value;
  @override
  Future<ServerUser> me(String token) async => value.user;
  @override
  Future<ServerContext> context(String token) async => value.context!;
}

http.Response _json(Object? value, [int status = 200]) => http.Response(
  value == null ? '' : jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  const core = 'a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0';
  const home = 'b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0';
  const accountId = 'c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0';
  const sessionId = 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0';
  const deviceId = 'e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0';
  const requestId = 'f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0';
  final context = ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': core,
    'homeId': home,
  });
  final endpoint = ServerEndpoint('https://synthetic.invalid/prefix');
  final session = ServerSession(
    endpoint: endpoint,
    accessToken: 'synthetic_access_1234567890',
    refreshToken: 'synthetic_refresh_1234567890',
    expiresAt: DateTime.now().add(const Duration(days: 1)),
    user: const ServerUser(
      id: accountId,
      username: 'Fixture',
      role: ServerRole.admin,
      mustChangePassword: false,
    ),
    context: context,
  );
  final authority = {
    'schemaVersion': 1,
    'coreId': core,
    'homeId': home,
    'accountId': accountId,
    'sessionFamilyId': sessionId,
    'homeRevision': 1,
    'accountRevision': 2,
    'sessionRevision': 1,
    'canManage': true,
  };
  Map<String, Object?> device({String trust = 'pending'}) => {
    'schemaVersion': 1,
    'authority': authority,
    'deviceId': deviceId,
    'name': 'Hall display',
    'deviceRevision': '7',
    'mappingRevision': 1,
    'bridgeRevision': '2',
    'layoutRevision': '4',
    'dataRevision': '9',
    'policyRevision': '5',
    'stored': true,
    'reachable': true,
    'snapshotTrust': trust,
    'snapshotDigest': '1' * 64,
    'verifiedDigest': null,
    'expiresAtMs': DateTime.utc(2030).millisecondsSinceEpoch,
  };

  test('legacy verified device claims cannot enter the client trust model', () {
    expect(
      () => EpaperDeviceStatus.fromJson(device(trust: 'verified')),
      throwsArgumentError,
    );
    final staleDigest = EpaperDeviceStatus.fromJson({
      ...device(trust: 'acknowledged'),
      'verifiedDigest': '1' * 64,
    });
    expect(staleDigest.isCoherentAt(DateTime.utc(2029)), isFalse);
  });

  test(
    'transport binds session and route and never replays late commands',
    () async {
      final account = ServerAccountController(
        store: _Store(session),
        apiFactory: (_) => _AuthApi(session),
      );
      addTearDown(account.dispose);
      await account.initialize();
      var current = true, calls = 0;
      final methods = <String>[];
      final client = MockClient((request) async {
        calls++;
        methods.add('${request.method} ${request.url.path}');
        expect(
          request.headers['authorization'],
          'Bearer ${session.accessToken}',
        );
        final path = request.url.path.replaceFirst('/prefix/api/v1', '');
        if (path.endsWith('/authority')) return _json(authority);
        if (path.endsWith('/devices')) {
          return _json({
            'schemaVersion': 1,
            'devices': [device()],
          });
        }
        if (path.endsWith('/previews')) {
          return _json({
            'schemaVersion': 1,
            'authority': authority,
            'requestId': requestId,
            'deviceId': deviceId,
            'deviceRevision': '7',
            'action': 'refresh',
            'expectedLayoutRevision': '4',
            'expiresAtMs': DateTime.utc(2030).millisecondsSinceEpoch,
          }, 201);
        }
        if (request.method == 'DELETE') return _json(null, 204);
        if (path.endsWith('/$deviceId')) return _json(device());
        throw StateError('unexpected request $path');
      });
      final api = await EpaperAccountApi.connect(
        account: account,
        context: context,
        routeId: '0' * 32,
        isCurrent: () => current,
        apiFactory: (value) =>
            LarenorServerApi(endpoint: value, client: client),
      );
      addTearDown(api.close);
      expect((await api.list(api.authority)).single.deviceId, deviceId);
      final preview = await api.preview(
        api.authority,
        deviceId: deviceId,
        expectedDeviceRevision: '7',
        action: EpaperManagementAction.refresh,
      );
      await api.cancel(api.authority, preview);
      expect(methods.any((value) => value.startsWith('DELETE ')), isTrue);

      current = false;
      await expectLater(
        api.preview(
          api.authority,
          deviceId: deviceId,
          expectedDeviceRevision: '7',
          action: EpaperManagementAction.refresh,
        ),
        throwsA(isA<EpaperApiException>()),
      );
      expect(calls, 4);
    },
  );

  test('malformed or foreign authority response fails closed', () async {
    final account = ServerAccountController(
      store: _Store(session),
      apiFactory: (_) => _AuthApi(session),
    );
    addTearDown(account.dispose);
    await account.initialize();
    final client = MockClient(
      (request) async => _json({...authority, 'homeId': '9' * 32}),
    );
    await expectLater(
      EpaperAccountApi.connect(
        account: account,
        context: context,
        routeId: '0' * 32,
        isCurrent: () => true,
        apiFactory: (value) =>
            LarenorServerApi(endpoint: value, client: client),
      ),
      throwsA(isA<EpaperApiException>()),
    );
  });
}
