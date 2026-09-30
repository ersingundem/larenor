import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/floor_plan/data/floor_plan_api.dart';
import 'package:larenor/features/floor_plan/data/floor_plan_editor_controller.dart';
import 'package:larenor/features/floor_plan/domain/floor_plan_editor_models.dart';
import 'package:larenor/features/floor_plan/domain/floor_plan_models.dart';
import 'package:larenor/features/floor_plan/data/floor_plan_controller.dart';
import 'package:larenor/features/floor_plan/presentation/floor_plan_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final _context = ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': '1' * 32,
  'homeId': '2' * 32,
});

const _roomId = '33333333333333333333333333333333';

Map<String, Object?> _editorResponse({Object? layout}) => {
  'schemaVersion': 1,
  'layoutRevision': layout == null ? 0 : 7,
  'entityRegistryRevision': 11,
  'resourceRevision': 13,
  'grantRevision': 17,
  'layout': layout,
  'rooms': [
    {'roomId': _roomId, 'label': 'Living room', 'revision': 19},
  ],
  'targets': [
    {
      'targetKind': 'entity',
      'targetId': 'light.living',
      'targetRevision': 23,
      'label': 'Living light',
    },
  ],
};

Map<String, Object?> _emptyEditorResponse() => {
  ..._editorResponse(),
  'layoutRevision': 0,
};

Map<String, Object?> _layout() => {
  'floors': [
    {'floorId': 'ground', 'label': 'Ground floor', 'order': 0},
  ],
  'rooms': [
    {
      'roomId': _roomId,
      'floorId': 'ground',
      'label': 'Living room',
      'polygon': [
        {'x': 0.1, 'y': 0.1},
        {'x': 0.9, 'y': 0.1},
        {'x': 0.9, 'y': 0.9},
      ],
    },
  ],
  'anchors': [
    {
      'anchorId': 'light-anchor',
      'roomId': _roomId,
      'targetKind': 'entity',
      'targetId': 'light.living',
      'targetRevision': 23,
      'x': 0.4,
      'y': 0.5,
      'rotation': 37.5,
    },
  ],
  'vectors': [
    {
      'shapeId': 'wall-1',
      'floorId': 'ground',
      'kind': 'wall',
      'points': [
        {'x': 0.1, 'y': 0.1},
        {'x': 0.9, 'y': 0.1},
      ],
    },
  ],
};

void main() {
  test('editor contract preserves vectors and anchor rotations on save', () {
    final catalog = FloorPlanEditorCatalog.fromResponse(
      _editorResponse(layout: _layout()),
      expected: _context,
    );
    final request = FloorPlanEditorSaveRequest.forCatalog(
      requestId: '4' * 32,
      catalog: catalog,
      layout: catalog.layout!,
    );
    final json = request.toJson();
    expect(json['expectedLayoutRevision'], 7);
    expect(json['expectedEntityRegistryRevision'], 11);
    expect(json['expectedResourceRevision'], 13);
    expect(json['expectedGrantRevision'], 17);
    final saved = json['layout']! as Map<String, dynamic>;
    expect((saved['anchors'] as List).single['rotation'], 37.5);
    expect((saved['vectors'] as List).single['shapeId'], 'wall-1');
  });

  test('editor API uses exact admin route and revision CAS body', () async {
    final requests = <http.Request>[];
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.example'),
      client: MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode(_editorResponse(layout: _layout())),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'receipt': {
              'requestId': '4' * 32,
              'revision': 8,
              'status': 'saved',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(api.close);
    final gateway = FloorPlanApi(api, 'token', _context);
    final catalog = await gateway.readEditor();
    final receipt = await gateway.saveEditor(
      FloorPlanEditorSaveRequest.forCatalog(
        requestId: '4' * 32,
        catalog: catalog,
        layout: catalog.layout!,
      ),
    );
    expect(receipt.revision, 8);
    expect(requests.map((item) => item.method), ['GET', 'PUT']);
    expect(requests.map((item) => item.url.path).toSet(), {
      '/api/v1/floor-plan/${_context.coreId}/${_context.homeId}/editor',
    });
    expect(
      requests.every((item) => item.headers['authorization'] == 'Bearer token'),
      isTrue,
    );
    final body = jsonDecode(requests.last.body) as Map<String, dynamic>;
    expect(body['expectedLayoutRevision'], 7);
    expect(body['expectedEntityRegistryRevision'], 11);
  });

  test(
    'controller blocks editing during uncertain action and never retries save',
    () async {
      var actionSafe = true;
      final gateway = _EditorGateway(
        FloorPlanEditorCatalog.fromResponse(
          _editorResponse(layout: _layout()),
          expected: _context,
        ),
      );
      final controller = FloorPlanEditorController(
        gateway: gateway,
        isCurrent: () => true,
        actionSafe: () => actionSafe,
        requestIds: () => '4' * 32,
      );
      await controller.load();
      controller.moveAnchor(
        'light-anchor',
        const FloorPlanEditorPoint(0.6, 0.7),
      );
      actionSafe = false;
      await controller.save();
      expect(gateway.saves, 0);
      actionSafe = true;
      expect(controller.dirty, isTrue);
      expect(controller.canMutate, isTrue);
      expect(
        () => FloorPlanEditorLayout.fromJson(controller.layout!.toJson()),
        returnsNormally,
      );
      expect(controller.canSave, isTrue);
      gateway.failure = const LarenorServerException('conflict');
      await controller.save();
      expect(gateway.saves, 1);
      expect(controller.needsReload, isTrue);
      await controller.save();
      expect(gateway.saves, 1);
    },
  );

  test('late save receipt is discarded when action safety changes', () async {
    var actionSafe = true;
    final catalog = FloorPlanEditorCatalog.fromResponse(
      _editorResponse(layout: _layout()),
      expected: _context,
    );
    final gateway = _DelayedEditorGateway(catalog);
    final controller = FloorPlanEditorController(
      gateway: gateway,
      isCurrent: () => true,
      actionSafe: () => actionSafe,
      requestIds: () => '4' * 32,
    );
    addTearDown(controller.dispose);
    await controller.load();
    controller.moveAnchor('light-anchor', const FloorPlanEditorPoint(0.6, 0.7));
    final save = controller.save();
    await gateway.entered.future;
    actionSafe = false;
    gateway.result.complete(
      FloorPlanEditorReceipt.fromResponse({
        'receipt': {'requestId': '4' * 32, 'revision': 8, 'status': 'saved'},
      }, expectedRequestId: '4' * 32),
    );
    await save;
    expect(controller.dirty, isTrue);
    expect(controller.saving, isFalse);
  });

  test(
    'empty home starts blank and accepts only catalog rooms and targets',
    () async {
      var id = 0;
      final controller = FloorPlanEditorController(
        gateway: _EditorGateway(
          FloorPlanEditorCatalog.fromResponse(
            _emptyEditorResponse(),
            expected: _context,
          ),
        ),
        isCurrent: () => true,
        actionSafe: () => true,
        requestIds: () => (++id).toRadixString(16).padLeft(32, '0'),
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.layout!.floors, isEmpty);
      controller.addFloor('Ground floor');
      final floor = controller.layout!.floors.single;
      final room = controller.catalog!.rooms.single;
      controller.addRoom(
        room: room,
        floorId: floor.id,
        polygon: const [
          FloorPlanEditorPoint(0.1, 0.1),
          FloorPlanEditorPoint(0.9, 0.1),
          FloorPlanEditorPoint(0.9, 0.9),
        ],
      );
      controller.addAnchor(
        target: controller.catalog!.targets.single,
        roomId: room.id,
        point: const FloorPlanEditorPoint(0.5, 0.5),
      );
      expect(controller.layout!.rooms.single.id, _roomId);
      expect(controller.layout!.anchors.single.targetId, 'light.living');
      expect(controller.canSave, isTrue);

      controller.addRoom(
        room: const FloorPlanEditorRoomCandidate(
          '55555555555555555555555555555555',
          'Forged',
          1,
        ),
        floorId: floor.id,
        polygon: const [
          FloorPlanEditorPoint(0.1, 0.1),
          FloorPlanEditorPoint(0.2, 0.1),
          FloorPlanEditorPoint(0.2, 0.2),
        ],
      );
      expect(controller.layout!.rooms, hasLength(1));
    },
  );

  testWidgets(
    'admin editor stays inline and uncertain actions keep it unavailable',
    (tester) async {
      final gateway = _EditorGateway(
        FloorPlanEditorCatalog.fromResponse(
          _editorResponse(layout: _layout()),
          expected: _context,
        ),
      );
      final controller = FloorPlanController(
        gateway: gateway,
        isCurrent: () => true,
      );
      await controller.load();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: FloorPlanScreen(
            controller: controller,
            strings: const FloorPlanStrings(
              title: 'Floor plan',
              loading: 'Loading',
              empty: 'Empty',
              offline: 'Offline',
              stale: 'Stale',
              invalid: 'Invalid',
              refresh: 'Refresh',
              zoomIn: 'Zoom in',
              zoomOut: 'Zoom out',
              accessibleRooms: 'Rooms',
              edit: 'Edit layout',
            ),
            canEdit: true,
          ),
        ),
      );
      final edit = find.descendant(
        of: find.byKey(const ValueKey('floor-plan-edit')),
        matching: find.byType(CupertinoButton),
      );
      expect(tester.widget<CupertinoButton>(edit).onPressed, isNotNull);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('floor-plan-editor-save')),
        findsOneWidget,
      );
      expect(find.byType(FloorPlanScreen), findsOneWidget);
      expect(gateway.editorReads, 1);

      await tester.tap(find.byKey(const ValueKey('floor-plan-editor-done')));
      await tester.pumpAndSettle();
      controller.actionState = FloorPlanActionState.uncertain;
      await controller.load();
      await tester.pump();
      final button = tester.widget<CupertinoButton>(
        find.descendant(
          of: find.byKey(const ValueKey('floor-plan-edit')),
          matching: find.byType(CupertinoButton),
        ),
      );
      expect(button.onPressed, isNull);
    },
  );
}

final class _DelayedEditorGateway implements FloorPlanEditorGateway {
  _DelayedEditorGateway(this.catalog);
  final FloorPlanEditorCatalog catalog;
  final entered = Completer<void>();
  final result = Completer<FloorPlanEditorReceipt>();

  @override
  Future<FloorPlanEditorCatalog> readEditor() async => catalog;

  @override
  Future<FloorPlanEditorReceipt> saveEditor(
    FloorPlanEditorSaveRequest request,
  ) {
    entered.complete();
    return result.future;
  }
}

final class _EditorGateway implements FloorPlanGateway, FloorPlanEditorGateway {
  _EditorGateway(this.catalog);
  final FloorPlanEditorCatalog catalog;
  Object? failure;
  int saves = 0;
  int editorReads = 0;

  @override
  Future<FloorPlanSnapshot> read() async {
    final response = _editorResponse(layout: _layout())
      ..remove('rooms')
      ..remove('targets')
      ..addAll({
        'projections': [
          {
            'anchorId': 'light-anchor',
            'targetKind': 'entity',
            'targetId': 'light.living',
            'targetRevision': 23,
            'state': 'on',
            'status': 'live',
            'capability': {
              'kind': 'none',
              'actions': <Object?>[],
              'resourceId': null,
              'resourceRevision': null,
              'aclRevision': null,
              'bindingId': null,
              'bindingRevision': null,
              'serviceRevision': null,
            },
          },
        ],
        'projectionLimit': 512,
        'projectionTruncated': false,
      });
    return FloorPlanSnapshot.fromResponse(response, expected: _context);
  }

  @override
  Future<FloorPlanEditorCatalog> readEditor() async {
    editorReads++;
    return catalog;
  }

  @override
  Future<FloorPlanEditorReceipt> saveEditor(
    FloorPlanEditorSaveRequest request,
  ) async {
    saves++;
    if (failure case final error?) throw error;
    return FloorPlanEditorReceipt.fromResponse({
      'receipt': {
        'requestId': request.requestId,
        'revision': catalog.layoutRevision + 1,
        'status': 'saved',
      },
    }, expectedRequestId: request.requestId);
  }
}
