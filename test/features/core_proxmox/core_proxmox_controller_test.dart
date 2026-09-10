import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/core_proxmox/data/core_proxmox_controller.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

class _Sessions implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? value) async => this.value = value;
}

class _Source implements HomeSourcePersistence {
  @override
  Future<HomeSource> read() async => HomeSource.verifiedCore;
  @override
  Future<void> write(HomeSource value) async {}
}

class _Auth extends LarenorServerApi {
  _Auth(this.h) : super(endpoint: ServerEndpoint('https://core.invalid'));
  final _Harness h;
  ServerSession fresh() => ServerSession(
    endpoint: endpoint,
    accessToken: 'a' * 43,
    refreshToken: 'b' * 43,
    expiresAt: h.now.add(const Duration(hours: 1)),
    user: ServerUser(
      id: 'f' * 32,
      username: 'fixture',
      role: h.admin ? ServerRole.admin : ServerRole.member,
      mustChangePassword: false,
    ),
  );
  @override
  Future<ServerSession> login({
    required String username,
    required String password,
    required String deviceName,
  }) async => fresh();
  @override
  Future<ServerSession> refresh(String token) async => fresh();
  @override
  Future<ServerContext> context(String token) async => h.context;
  @override
  Future<ServerUser> me(String token) async => fresh().user;
  @override
  Future<void> logout(ServerSession session) async {}
}

class _Harness {
  final f = jsonDecode(
    File('contracts/proxmox-resource.v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  DateTime now = DateTime.utc(2026, 9, 10, 12);
  Duration elapsed = Duration.zero;
  bool admin = false, current = true, bound = true;
  Completer<http.Response>? delayed;
  int closes = 0;
  late final context = ServerContext.fromJson(f['context']);
  late final account = ServerAccountController(
    store: _Sessions(),
    apiFactory: (_) => _Auth(this),
    clock: () => now,
  );
  late final home = HomeSessionController(store: _Source(), account: account);
  late final target = HomeResourceRecord.fromJson(
    f['resource'],
    expectedContext: context,
  );
  final owner = ChangeNotifier();

  Future<void> start() async {
    await account.initialize();
    await home.initialize();
    await account.signIn(
      baseUrl: 'https://core.invalid',
      username: 'x',
      password: 'x',
      deviceName: 'x',
    );
    home.runtimeMounted(home.runtimeIdentity);
  }

  LarenorServerApi transport(ServerEndpoint endpoint) => LarenorServerApi(
    endpoint: endpoint,
    client: _TrackedClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/snapshot')) {
        return delayed?.future ?? _json({'snapshot': f['snapshot']});
      }
      if (path.endsWith('/binding-preview')) {
        final binding = {...f['binding'] as Map, 'id': '7' * 32, 'revision': 3};
        return _json({
          'preview': {
            ...f['preview'] as Map,
            'binding': binding,
            'summary': f['summary'],
          },
        }, 201);
      }
      if (path.endsWith('/binding-confirm')) {
        final binding = {...f['binding'] as Map, 'id': '7' * 32, 'revision': 3};
        return _json({'binding': binding}, 201);
      }
      if (path.endsWith('/binding')) {
        return bound
            ? _json({'binding': f['binding']})
            : _json({
                'error': {'code': 'not_found'},
              }, 404);
      }
      if (path.endsWith('/services')) {
        return _json({
          'services': [f['service']],
        });
      }
      if (path.contains('/home-resources/')) {
        return _json({'record': f['resource']});
      }
      if (request.method == 'DELETE') {
        return http.Response('', 204);
      }
      throw StateError('unexpected $request');
    }, () => closes++),
  );

  CoreProxmoxController controller() => CoreProxmoxController(
    home,
    target,
    transport,
    () => now,
    () => elapsed,
    () => current,
    owner,
    admin: admin,
  );

  Future<void> close() async {
    owner.dispose();
    home.dispose();
    account.dispose();
  }
}

class _TrackedClient extends MockClient {
  _TrackedClient(super.fn, this.onClose);
  final VoidCallback onClose;
  @override
  void close() {
    onClose();
    super.close();
  }
}

http.Response _json(Object? value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Future<void> _flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('member snapshot expires and never exposes stale data', () async {
    final h = _Harness();
    await h.start();
    final controller = h.controller();
    controller.setVisible(true);
    await _flush();
    expect(controller.snapshot?.summary.nodes, hasLength(2));
    h.elapsed = const Duration(seconds: 5);
    controller.synchronize();
    expect(controller.stale, isTrue);
    expect(controller.snapshot, isNull);
    controller.dispose();
    await h.close();
  });

  test('late response after lifecycle retirement is discarded', () async {
    final h = _Harness();
    await h.start();
    h.delayed = Completer();
    final controller = h.controller();
    controller.setVisible(true);
    await _flush();
    h.current = false;
    h.owner.notifyListeners();
    h.delayed!.complete(_json({'snapshot': h.f['snapshot']}));
    await _flush();
    expect(controller.snapshot, isNull);
    expect(controller.failure, isNull);
    expect(h.closes, greaterThan(0));
    controller.dispose();
    await h.close();
  });

  test(
    'admin explicitly previews and confirms one selected Core service',
    () async {
      final h = _Harness()..admin = true;
      await h.start();
      final controller = h.controller();
      controller.setVisible(true);
      await _flush();
      expect(controller.binding?.id, '5' * 32);
      expect(controller.services, hasLength(1));
      await controller.prepare(
        controller.services.single,
        isCurrent: () => true,
      );
      expect(controller.preview?.binding.id, '7' * 32);
      await controller.confirm(controller.preview!, isCurrent: () => true);
      expect(controller.saved, isTrue);
      expect(controller.binding?.id, '7' * 32);
      controller.dispose();
      await h.close();
    },
  );
}
