import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/local_notifications/data/local_notification_api.dart';
import 'package:larenor/features/local_notifications/data/local_notification_controller.dart';
import 'package:larenor/features/local_notifications/data/local_notification_store.dart';
import 'package:larenor/features/local_notifications/domain/local_notification_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const _coreId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _homeId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _userId = 'cccccccccccccccccccccccccccccccc';
const _eventId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const _token = 'synthetic_loopback_access_token_1234567890';

final class _SessionStore implements ServerSessionPersistence {
  _SessionStore(this.value);
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _SourceStore implements HomeSourcePersistence {
  @override
  Future<HomeSource> read() async => HomeSource.verifiedCore;
  @override
  Future<void> write(HomeSource source) async {}
}

final class _MemoryNotificationStore implements LocalNotificationStoreBackend {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

final class _Owner extends ChangeNotifier implements LocalNotificationOwner {
  bool current = true;
  @override
  bool get isCurrent => current;
  void setCurrent(bool value) {
    current = value;
    notifyListeners();
  }
}

final class _Permission implements LocalNotificationPermissionGateway {
  @override
  Future<LocalNotificationPermission> read() async =>
      LocalNotificationPermission.inAppOnly;
}

final class _LoopbackCore {
  _LoopbackCore._(this.server) {
    unawaited(_serve());
  }

  final HttpServer server;
  String? registrationId;
  int subscriptionRevision = 1;
  double? expiresAt;
  bool acknowledged = false;
  int registerCalls = 0, pullCalls = 0, ackCalls = 0;
  String? wrongScopeHome;
  int? wrongSubscriptionRevision;
  bool malformed = false, dropNextPull = false, duplicateIdentity = false;
  Completer<void>? pullBarrier;

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  static Future<_LoopbackCore> start() async =>
      _LoopbackCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> _serve() async {
    await for (final request in server) {
      unawaited(_handle(request).catchError((Object _) {}));
    }
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    return text.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $_token') {
      return _error(request, 401, 'invalid_session');
    }
    if (path == '/api/v1/auth/me') {
      return _json(request, {
        'user': {
          'id': _userId,
          'username': 'loopback',
          'role': 'member',
          'mustChangePassword': false,
        },
      });
    }
    if (path == '/api/v1/context') {
      return _json(request, _scope());
    }
    final root = '/api/v1/local-notifications/$_coreId/$_homeId';
    if (!path.startsWith(root)) return _error(request, 404, 'not_found');
    if (request.method == 'POST' && path == '$root/subscriptions') {
      registerCalls++;
      final body = await _body(request);
      final id = body['registrationId'];
      if (id is! String || body['schemaVersion'] != 1) {
        return _error(request, 400, 'invalid_request');
      }
      if (registrationId != null &&
          (registrationId != id || expiresAt != body['expiresAt'])) {
        return _error(request, 409, 'notification_registration_replay');
      }
      registrationId ??= id;
      expiresAt ??= (body['expiresAt'] as num).toDouble();
      return _json(request, _subscription(), 201);
    }
    final id = registrationId;
    if (id == null || !path.contains('/subscriptions/$id/')) {
      return _error(request, 404, 'not_found');
    }
    if (request.method == 'GET' && path.endsWith('/events')) {
      pullCalls++;
      if (dropNextPull) {
        dropNextPull = false;
        final socket = await request.response.detachSocket();
        socket.destroy();
        return;
      }
      final barrier = pullBarrier;
      if (barrier != null) await barrier.future;
      final expected = int.tryParse(
        request.uri.queryParameters['expectedRevision'] ?? '',
      );
      if (expected != subscriptionRevision) {
        return _error(request, 409, 'notification_subscription_changed');
      }
      if (malformed) return _json(request, {'schemaVersion': 1});
      final after = int.parse(request.uri.queryParameters['after'] ?? '0');
      final events = <Map<String, Object?>>[];
      if (after < 1) events.add(_event());
      if (duplicateIdentity && after >= 1) {
        events.add(_event(sequence: 2, id: _eventId));
      }
      return _json(request, {
        'schemaVersion': 1,
        'scope': _scope(homeId: wrongScopeHome),
        'subscriptionRevision':
            wrongSubscriptionRevision ?? subscriptionRevision,
        'events': events,
        'nextAfter': duplicateIdentity && after == 0 ? 1 : null,
      });
    }
    if (request.method == 'POST' && path.endsWith('/acknowledgements')) {
      ackCalls++;
      final body = await _body(request);
      if (body['expectedSubscriptionRevision'] != subscriptionRevision ||
          jsonEncode(body['sequences']) != '[1]') {
        return _error(request, 409, 'notification_subscription_changed');
      }
      acknowledged = true;
      return _json(request, {
        'schemaVersion': 1,
        'subscriptionRevision': subscriptionRevision,
        'acknowledgedThrough': 1,
      });
    }
    return _error(request, 404, 'not_found');
  }

  Map<String, Object> _scope({String? homeId}) => {
    'schemaVersion': 1,
    'coreId': _coreId,
    'homeId': homeId ?? _homeId,
  };

  Map<String, Object?> _subscription() => {
    'subscription': {
      'schemaVersion': 1,
      'ref': {
        ..._scope(),
        'kind': 'local_notification_subscription',
        'id': registrationId,
      },
      'revision': subscriptionRevision,
      'permission': 'granted',
      'state': 'active',
      'expiresAt': expiresAt,
    },
  };

  Map<String, Object?> _event({int sequence = 1, String id = _eventId}) => {
    'schemaVersion': 1,
    'id': id,
    'sequence': sequence,
    'category': 'security',
    'sensitivity': 'private',
    'title': 'Private door event',
    'body': 'Private event body',
    'target': '/today',
    'createdAt': 1789920000.0,
    'deliveryState': 'delivered',
    'readState': acknowledged ? 'read' : 'unread',
    'acknowledged': acknowledged,
    'publicProjection': {
      'title': 'Larenor',
      'body': '',
      'target': null,
      'redacted': true,
    },
  };

  void _json(HttpRequest request, Object value, [int status = 200]) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(value))
      ..close();
  }

  void _error(HttpRequest request, int status, String code) => _json(request, {
    'error': {'code': code},
  }, status);
}

final class _Harness {
  _Harness._({
    required this.core,
    required this.account,
    required this.home,
    required this.owner,
    required this.controller,
  });

  final _LoopbackCore core;
  final ServerAccountController account;
  final HomeSessionController home;
  final _Owner owner;
  final LocalNotificationController controller;

  static Future<_Harness> start() async {
    final core = await _LoopbackCore.start();
    final now = DateTime.utc(2026, 9, 20, 12);
    final endpoint = ServerEndpoint(core.baseUrl);
    final stored = ServerSession(
      endpoint: endpoint,
      accessToken: _token,
      refreshToken: 'synthetic_loopback_refresh_token_123456789',
      expiresAt: now.add(const Duration(hours: 1)),
      user: const ServerUser(
        id: _userId,
        username: 'loopback',
        role: ServerRole.member,
        mustChangePassword: false,
      ),
    );
    final account = ServerAccountController(
      store: _SessionStore(stored),
      clock: () => now,
      apiFactory: (endpoint) => LarenorServerApi(endpoint: endpoint),
    );
    await account.initialize();
    final home = HomeSessionController(store: _SourceStore(), account: account);
    await home.initialize();
    home.runtimeMounted(home.runtimeIdentity);
    final owner = _Owner();
    final controller = LocalNotificationController(
      home: home,
      apiFactory: (endpoint) => LarenorServerApi(endpoint: endpoint),
      store: LocalNotificationStore(backend: _MemoryNotificationStore()),
      permissionGateway: _Permission(),
      clock: () => now,
      windowCurrent: () => true,
      owner: owner,
    );
    return _Harness._(
      core: core,
      account: account,
      home: home,
      owner: owner,
      controller: controller,
    );
  }

  Future<void> load() async {
    controller.setVisible(true);
    await settle();
  }

  Future<void> settle() async {
    for (var i = 0; i < 200 && controller.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(controller.busy, isFalse);
  }

  Future<void> close() async {
    controller.dispose();
    owner.dispose();
    home.dispose();
    account.dispose();
    await core.server.close(force: true);
  }
}

void main() {
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = null);

  test(
    'register pull acknowledge and exact readback cross real HTTP',
    () async {
      final harness = await _Harness.start();
      addTearDown(harness.close);
      await harness.load();
      expect(harness.controller.loaded, isTrue);
      expect(
        harness.controller.events.single.readState,
        LocalNotificationReadState.unread,
      );
      expect(harness.core.registerCalls, 1);
      expect(harness.core.pullCalls, 1);

      expect(
        await harness.controller.markRead(
          harness.controller.events.single,
          interactionCurrent: () => true,
        ),
        isTrue,
      );
      expect(harness.core.ackCalls, 1);
      expect(harness.core.pullCalls, 2);
      expect(
        harness.controller.events.single.readState,
        LocalNotificationReadState.read,
      );
    },
  );

  test('scope revision session and malformed responses fail closed', () async {
    final harness = await _Harness.start();
    addTearDown(harness.close);
    harness.core.wrongScopeHome = 'f' * 32;
    await harness.load();
    expect(harness.controller.loaded, isFalse);
    expect(harness.controller.events, isEmpty);
    expect(harness.controller.failure, 'invalid_response');

    harness.core.wrongScopeHome = null;
    harness.core.wrongSubscriptionRevision = 99;
    await harness.controller.refresh();
    expect(harness.controller.failure, 'invalid_response');
    expect(harness.controller.events, isEmpty);

    harness.core.wrongSubscriptionRevision = null;
    harness.core.malformed = true;
    await harness.controller.refresh();
    expect(harness.controller.failure, 'invalid_response');
    expect(harness.controller.events, isEmpty);

    final transport = LarenorServerApi(
      endpoint: ServerEndpoint(harness.core.baseUrl),
    );
    addTearDown(transport.close);
    final active = harness.account.session!;
    await expectLater(
      LocalNotificationApi(transport, active, isCurrent: () => true).register(
        id: harness.core.registrationId!,
        expiresAt: DateTime.utc(2026, 10, 21),
      ),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'notification_registration_replay',
        ),
      ),
    );
    final foreignScope = ServerSession(
      endpoint: active.endpoint,
      accessToken: active.accessToken,
      refreshToken: active.refreshToken,
      expiresAt: active.expiresAt,
      context: ServerContext.fromJson({
        'schemaVersion': 1,
        'coreId': 'f' * 32,
        'homeId': _homeId,
      }),
      user: active.user,
    );
    await expectLater(
      LocalNotificationApi(
        transport,
        foreignScope,
        isCurrent: () => true,
      ).register(id: 'd' * 32, expiresAt: DateTime.utc(2026, 10, 20)),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'not_found',
        ),
      ),
    );
    final wrongSession = ServerSession(
      endpoint: ServerEndpoint(harness.core.baseUrl),
      accessToken: 'wrong_session_token_that_is_never_authorized',
      refreshToken: 'wrong_refresh_token_that_is_never_authorized',
      expiresAt: DateTime.utc(2026, 9, 20, 13),
      context: ServerContext.fromJson(harness.core._scope()),
      user: const ServerUser(
        id: _userId,
        username: 'loopback',
        role: ServerRole.member,
        mustChangePassword: false,
      ),
    );
    await expectLater(
      LocalNotificationApi(
        transport,
        wrongSession,
        isCurrent: () => true,
      ).register(id: 'd' * 32, expiresAt: DateTime.utc(2026, 10, 20)),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'unauthorized',
        ),
      ),
    );
  });

  test(
    'lost and late pulls reconnect while duplicate identities fail closed',
    () async {
      final harness = await _Harness.start();
      addTearDown(harness.close);
      harness.core.dropNextPull = true;
      await harness.load();
      expect(harness.controller.loaded, isFalse);
      expect(
        harness.controller.failure,
        anyOf('connection_failed', 'invalid_response'),
      );
      await harness.controller.refresh();
      expect(harness.controller.loaded, isTrue);
      expect(harness.core.registerCalls, 2);
      expect(harness.controller.events, hasLength(1));

      harness.core.duplicateIdentity = true;
      await harness.controller.refresh();
      expect(harness.controller.nextAfter, 1);
      await harness.controller.loadMore();
      expect(harness.controller.failure, 'invalid_response');
      expect(harness.controller.events, hasLength(1));

      final barrier = Completer<void>();
      harness.core
        ..duplicateIdentity = false
        ..pullBarrier = barrier;
      final pending = harness.controller.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      harness.owner.setCurrent(false);
      barrier.complete();
      await pending;
      expect(harness.controller.events, isEmpty);
      expect(harness.controller.loaded, isFalse);
      harness.owner.setCurrent(true);
      harness.core.pullBarrier = null;
      await harness.controller.refresh();
      expect(harness.controller.loaded, isTrue);
      expect(harness.controller.events, hasLength(1));
    },
  );
}
