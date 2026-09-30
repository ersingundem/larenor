import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/floor_plan/data/floor_plan_api.dart';
import 'package:larenor/features/floor_plan/domain/floor_plan_editor_models.dart';
import 'package:larenor/features/floor_plan/domain/floor_plan_models.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;
  @override
  Future<void> write(ServerSession? session) async {}
}

void main() {
  final coreUrl = Platform.environment['LARENOR_FLOOR_PLAN_CORE_URL'];
  final phase = Platform.environment['LARENOR_FLOOR_PLAN_PHASE'];
  setUpAll(() => HttpOverrides.global = null);

  test('real Client saves floor geometry with CAS and survives Core restart', () async {
    final account = ServerAccountController(store: _Store());
    addTearDown(account.dispose);
    await account.signIn(
      baseUrl: coreUrl!,
      username: 'admin',
      password: 'Synthetic new password 2026',
      deviceName: 'Floor plan acceptance',
    );
    expect(account.failure, isNull);
    final context = account.session!.context!;
    var current = true;
    final gateway = FloorPlanAccountGateway(
      account: account,
      context: context,
      isCurrent: () => current,
    );
    addTearDown(gateway.close);
    var catalog = await gateway.readEditor();
    expect(catalog.rooms.single.label, 'Living room');
    expect(
      catalog.targets.singleWhere((target) => target.kind == 'resource').label,
      phase == 'save' ? 'Synthetic switch' : 'Living TV renamed',
    );
    if (phase == 'save') {
      expect(catalog.layout, isNull);
      final room = catalog.rooms.single;
      final target = catalog.targets.singleWhere(
        (target) => target.kind == 'resource',
      );
      final layout = FloorPlanEditorLayout.fromJson({
        'floors': [
          {'floorId': 'ground', 'label': 'Ground floor', 'order': 0},
        ],
        'rooms': [
          {
            'roomId': room.id,
            'floorId': 'ground',
            'label': room.label,
            'polygon': [
              {'x': 0.1, 'y': 0.1},
              {'x': 0.9, 'y': 0.1},
              {'x': 0.9, 'y': 0.9},
            ],
          },
        ],
        'anchors': [
          {
            'anchorId': 'tv',
            'roomId': room.id,
            'targetKind': target.kind,
            'targetId': target.id,
            'targetRevision': target.revision,
            'x': 0.4,
            'y': 0.5,
            'rotation': 37.5,
          },
        ],
        'vectors': [
          {
            'shapeId': 'north-wall',
            'floorId': 'ground',
            'kind': 'wall',
            'points': [
              {'x': 0.1, 'y': 0.1},
              {'x': 0.9, 'y': 0.1},
            ],
          },
        ],
      });
      final request = FloorPlanEditorSaveRequest.forCatalog(
        requestId: '1' * 32,
        catalog: catalog,
        layout: layout,
      );
      final receipt = await gateway.saveEditor(request);
      expect(receipt.revision, 1);
      expect((await gateway.saveEditor(request)).revision, receipt.revision);
      final snapshot = await gateway.read();
      final projection = snapshot.projections['tv']!;
      expect(projection.status, FloorPlanProjectionStatus.live);
      expect(projection.state, 'off');
      final action = FloorPlanActionRequest.forProjection(
        requestId: '4' * 32,
        snapshot: snapshot,
        projection: projection,
        action: FloorPlanAction.turnOn,
      );
      expect(
        (await gateway.action(
          action,
          expectedSnapshot: snapshot,
        )).dispatchState,
        FloorPlanDispatchState.accepted,
      );
      expect(
        (await gateway.action(
          action,
          expectedSnapshot: snapshot,
        )).dispatchState,
        FloorPlanDispatchState.accepted,
      );
      await account.withSession(
        (api, session) => api.request(
          'PATCH',
          '/admin/home-resources/${context.coreId}/${context.homeId}/${target.id}',
          token: session.accessToken,
          body: {
            'label': 'Living TV renamed',
            'order': 0,
            'expectedRevision': target.revision,
            'expectedAclRevision': 1,
          },
        ),
      );
      await expectLater(
        gateway.saveEditor(
          FloorPlanEditorSaveRequest.forCatalog(
            requestId: '2' * 32,
            catalog: catalog,
            layout: layout,
          ),
        ),
        throwsA(isA<LarenorServerException>()),
      );
      catalog = await gateway.readEditor();
      final updated = catalog.layout!.toJson();
      (updated['anchors'] as List).single['targetRevision'] = catalog.targets
          .singleWhere((target) => target.kind == 'resource')
          .revision;
      final repaired = await gateway.saveEditor(
        FloorPlanEditorSaveRequest.forCatalog(
          requestId: '3' * 32,
          catalog: catalog,
          layout: FloorPlanEditorLayout.fromJson(updated),
        ),
      );
      expect(repaired.revision, 2);
      catalog = await gateway.readEditor();
    }
    expect(catalog.layoutRevision, 2);
    expect(catalog.layout!.anchors.single.rotation, 37.5);
    expect(catalog.layout!.anchors.single.targetRevision, 2);
    expect(catalog.layout!.vectors.single.id, 'north-wall');
    expect((await gateway.read()).revision, 2);
    current = false;
    await expectLater(
      gateway.readEditor(),
      throwsA(
        isA<LarenorServerException>().having(
          (value) => value.code,
          'code',
          'cancelled',
        ),
      ),
    );
  }, skip: coreUrl == null ? 'Requires isolated normal Core runner' : false);
}
