import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/floor_plan/data/floor_plan_api.dart';
import 'package:larenor/features/floor_plan/domain/floor_plan_editor_models.dart';
import 'package:larenor/features/floor_plan/domain/floor_plan_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const _core = '11111111111111111111111111111111';
const _home = '22222222222222222222222222222222';
const _account = '33333333333333333333333333333333';
const _resource = '44444444444444444444444444444444';
const _binding = '55555555555555555555555555555555';
const _request = '66666666666666666666666666666666';
const _editorRequest = '77777777777777777777777777777777';
const _catalogRoom = '88888888888888888888888888888888';
const _access = 'floor_plan_loopback_access_token_12345678901';

final class _Store implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _FloorPlanCore {
  _FloorPlanCore._(this.server) {
    unawaited(_serve());
  }

  final HttpServer server;
  int reads = 0, actions = 0, editorReads = 0, editorSaves = 0;
  Completer<void>? entered, barrier;
  String get baseUrl => 'http://127.0.0.1:${server.port}';

  static Future<_FloorPlanCore> start() async =>
      _FloorPlanCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> _serve() async {
    await for (final request in server) {
      unawaited(_handle(request).catchError((Object _) {}));
    }
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async =>
      jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (request.method == 'POST' && path == '/api/v1/auth/login') {
      await _body(request);
      return _json(request, {
        'accessToken': _access,
        'refreshToken': 'floor_plan_loopback_refresh_token_123456789',
        'expiresIn': 3600,
        'user': {
          'id': _account,
          'username': 'admin',
          'role': 'admin',
          'mustChangePassword': false,
        },
      });
    }
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $_access') {
      return _error(request, 401);
    }
    if (request.method == 'GET' && path == '/api/v1/context') {
      return _json(request, {
        'schemaVersion': 1,
        'coreId': _core,
        'homeId': _home,
      });
    }
    final root = '/api/v1/floor-plan/$_core/$_home';
    if (request.method == 'GET' && path == '$root/editor') {
      editorReads++;
      return _json(request, _editor());
    }
    if (request.method == 'PUT' && path == '$root/editor') {
      editorSaves++;
      final body = await _body(request);
      final layout = body['layout'] as Map<String, dynamic>?;
      final anchor = (layout?['anchors'] as List?)?.singleOrNull;
      final vectors = layout?['vectors'] as List?;
      if (body['requestId'] != _editorRequest ||
          body['expectedLayoutRevision'] != 7 ||
          body['expectedEntityRegistryRevision'] != 11 ||
          body['expectedResourceRevision'] != 13 ||
          body['expectedGrantRevision'] != 17 ||
          anchor is! Map<String, dynamic> ||
          anchor['rotation'] != 0.0 ||
          vectors?.length != 1) {
        return _error(request, 409);
      }
      return _json(request, {
        'receipt': {
          'requestId': _editorRequest,
          'revision': 8,
          'status': 'saved',
        },
      });
    }
    if (request.method == 'GET' && path == root) {
      reads++;
      entered?.complete();
      await barrier?.future;
      return _json(request, _snapshot());
    }
    if (request.method == 'POST' && path == '$root/actions') {
      actions++;
      final body = await _body(request);
      if (body['requestId'] != _request ||
          body['anchorId'] != 'light' ||
          body['action'] != 'turn_off' ||
          body['expectedLayoutRevision'] != 7 ||
          body['expectedEntityRegistryRevision'] != 11 ||
          body['expectedResourceRegistryRevision'] != 13 ||
          body['expectedGrantRevision'] != 17 ||
          body['expectedTargetRevision'] != 3 ||
          body['expectedResourceId'] != _resource ||
          body['expectedBindingId'] != _binding) {
        return _error(request, 409);
      }
      return _json(request, _receipt());
    }
    return _error(request, 404);
  }

  Map<String, dynamic> _snapshot() => {
    'schemaVersion': 1,
    'layoutRevision': 7,
    'entityRegistryRevision': 11,
    'resourceRevision': 13,
    'grantRevision': 17,
    'layout': {
      'floors': [
        {'floorId': 'ground', 'label': 'Ground floor', 'order': 0},
      ],
      'rooms': [
        {
          'roomId': 'living',
          'floorId': 'ground',
          'label': 'Living room',
          'polygon': [
            {'x': 0.05, 'y': 0.05},
            {'x': 0.95, 'y': 0.05},
            {'x': 0.95, 'y': 0.95},
          ],
        },
      ],
      'anchors': [
        {
          'anchorId': 'light',
          'roomId': 'living',
          'targetKind': 'entity',
          'targetId': 'light.living',
          'targetRevision': 3,
          'x': 0.5,
          'y': 0.5,
          'rotation': 0.0,
        },
      ],
      'vectors': [
        {
          'shapeId': 'wall',
          'floorId': 'ground',
          'kind': 'wall',
          'points': [
            {'x': 0.05, 'y': 0.05},
            {'x': 0.95, 'y': 0.05},
          ],
        },
      ],
    },
    'projections': [
      {
        'anchorId': 'light',
        'targetKind': 'entity',
        'targetId': 'light.living',
        'targetRevision': 3,
        'state': 'on',
        'status': 'live',
        'capability': {
          'kind': 'home_assistant.switch',
          'actions': ['turn_on', 'turn_off'],
          'resourceId': _resource,
          'resourceRevision': 19,
          'aclRevision': 23,
          'bindingId': _binding,
          'bindingRevision': 29,
          'serviceRevision': 31,
        },
      },
    ],
    'projectionLimit': 512,
    'projectionTruncated': false,
  };

  Map<String, dynamic> _editor() => {
    'schemaVersion': 1,
    'layoutRevision': 7,
    'entityRegistryRevision': 11,
    'resourceRevision': 13,
    'grantRevision': 17,
    'layout': _snapshot()['layout'],
    'rooms': [
      {'roomId': _catalogRoom, 'label': 'Office', 'revision': 37},
    ],
    'targets': [
      {
        'targetKind': 'entity',
        'targetId': 'light.office',
        'targetRevision': 41,
        'label': 'Office light',
      },
    ],
  };

  Map<String, dynamic> _receipt() => {
    'receipt': {
      'schemaVersion': 1,
      'anchorId': 'light',
      'layoutRevision': 7,
      'entityRegistryRevision': 11,
      'resourceRevision': 13,
      'grantRevision': 17,
      'command': {
        'schemaVersion': 1,
        'requestId': _request,
        'ref': {
          'schemaVersion': 1,
          'coreId': _core,
          'homeId': _home,
          'kind': 'resource',
          'id': _resource,
        },
        'bindingId': _binding,
        'bindingRevision': 29,
        'actorId': _account,
        'action': 'turn_off',
        'dispatchState': 'accepted',
        'providerAccepted': true,
        'observedProjection': {
          'kind': 'switch',
          'state': 'off',
          'commandAvailable': true,
        },
        'observationMatchesTarget': true,
        'causalityVerified': false,
        'createdAt': '2026-09-30T09:00:00Z',
        'completedAt': '2026-09-30T09:00:01Z',
      },
    },
  };

  Future<void> close() => server.close(force: true);
}

void _json(HttpRequest request, Object body, [int status = 200]) {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  unawaited(request.response.close());
}

void _error(HttpRequest request, int status) => _json(request, {
  'error': {'code': 'conflict'},
}, status);

Future<ServerAccountController> _signIn(_FloorPlanCore core) async {
  final account = ServerAccountController(
    store: _Store(),
    apiFactory: (endpoint) => LarenorServerApi(endpoint: endpoint),
  );
  await account.signIn(
    baseUrl: core.baseUrl,
    username: 'admin',
    password: 'synthetic-password',
    deviceName: 'tablet',
  );
  return account;
}

void main() {
  setUpAll(() => HttpOverrides.global = null);

  test(
    'production client reads live placement and dispatches action',
    () async {
      final core = await _FloorPlanCore.start();
      addTearDown(core.close);
      final account = await _signIn(core);
      addTearDown(account.dispose);
      final gateway = FloorPlanAccountGateway(
        account: account,
        context: account.session!.context!,
        isCurrent: () => true,
      );
      addTearDown(gateway.close);
      final snapshot = await gateway.read();
      expect(snapshot.rooms.single.label, 'Living room');
      expect(snapshot.anchors.single.targetId, 'light.living');
      final projection = snapshot.projections['light']!;
      expect(projection.status, FloorPlanProjectionStatus.live);
      expect(projection.state, 'on');
      final request = FloorPlanActionRequest.forProjection(
        requestId: _request,
        snapshot: snapshot,
        projection: projection,
        action: FloorPlanAction.turnOff,
      );
      final receipt = await gateway.action(request, expectedSnapshot: snapshot);
      expect(receipt.dispatchState, FloorPlanDispatchState.accepted);
      expect((core.reads, core.actions), (1, 1));
    },
  );

  test('production account client reads and saves editor over TCP', () async {
    final core = await _FloorPlanCore.start();
    addTearDown(core.close);
    final account = await _signIn(core);
    addTearDown(account.dispose);
    final gateway = FloorPlanAccountGateway(
      account: account,
      context: account.session!.context!,
      isCurrent: () => true,
    );
    addTearDown(gateway.close);
    final catalog = await gateway.readEditor();
    expect(catalog.rooms.single.id, _catalogRoom);
    expect(catalog.targets.single.id, 'light.office');
    expect(catalog.layout!.vectors.single.id, 'wall');
    final receipt = await gateway.saveEditor(
      FloorPlanEditorSaveRequest.forCatalog(
        requestId: _editorRequest,
        catalog: catalog,
        layout: catalog.layout!,
      ),
    );
    expect(receipt.revision, 8);
    expect((core.editorReads, core.editorSaves), (1, 1));
  });

  test(
    'late floor plan is cancelled after account authority changes',
    () async {
      final core = await _FloorPlanCore.start();
      addTearDown(core.close);
      final account = await _signIn(core);
      addTearDown(account.dispose);
      var current = true;
      core.entered = Completer<void>();
      core.barrier = Completer<void>();
      final gateway = FloorPlanAccountGateway(
        account: account,
        context: account.session!.context!,
        isCurrent: () => current,
      );
      addTearDown(gateway.close);
      final pending = gateway.read();
      await core.entered!.future;
      current = false;
      core.barrier!.complete();
      await expectLater(
        pending,
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
    },
  );
}
