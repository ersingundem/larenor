import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/floor_plan/data/floor_plan_api.dart';
import 'package:larenor/features/floor_plan/data/floor_plan_controller.dart';
import 'package:larenor/features/floor_plan/domain/floor_plan_models.dart';
import 'package:larenor/features/floor_plan/presentation/floor_plan_screen.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final context = ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': '1' * 32,
  'homeId': '2' * 32,
});

Map<String, Object?> response() => {
  'layoutRevision': 7,
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
};

const strings = FloorPlanStrings(
  title: 'Floor plan',
  loading: 'Loading floor plan',
  empty: 'No floor plan',
  offline: 'Core is offline',
  stale: 'Session changed; result discarded',
  invalid: 'Unverified Core response',
  refresh: 'Refresh',
  zoomIn: 'Zoom in',
  zoomOut: 'Zoom out',
  accessibleRooms: 'Rooms and devices',
);

void main() {
  test('strict Core API binds token and exact home route', () async {
    final requests = <http.Request>[];
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.example'),
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(response()),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(transport.close);
    final snapshot = await FloorPlanApi(transport, 'token', context).read();
    expect(snapshot.revision, 7);
    expect(snapshot.context, context);
    expect(snapshot.rooms.single.label, 'Living room');
    expect(requests.single.method, 'GET');
    expect(
      requests.single.url.path,
      '/api/v1/floor-plan/${context.coreId}/${context.homeId}',
    );
    expect(requests.single.headers['authorization'], 'Bearer token');
    final malformed = response()..['layoutRevision'] = 0;
    expect(
      () => FloorPlanSnapshot.fromResponse(malformed, expected: context),
      throwsA(isA<LarenorServerException>()),
    );
  });

  test(
    'controller discards late result after route authority retires',
    () async {
      final result = Completer<FloorPlanSnapshot>();
      var current = true;
      final controller = FloorPlanController(
        gateway: _Gateway(result.future),
        isCurrent: () => current,
      );
      final load = controller.load();
      current = false;
      controller.retire();
      result.complete(
        FloorPlanSnapshot.fromResponse(response(), expected: context),
      );
      await load;
      expect(controller.snapshot, isNull);
      expect(controller.failure, FloorPlanFailure.stale);
    },
  );

  for (final width in [600.0, 1280.0]) {
    testWidgets('tablet $width supports 2x text keyboard and TalkBack', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = FloorPlanController(
        gateway: _Gateway(
          Future.value(
            FloorPlanSnapshot.fromResponse(response(), expected: context),
          ),
        ),
        isCurrent: () => true,
      );
      await controller.load();
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        CupertinoApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: const TextScaler.linear(2),
            ),
            child: FloorPlanScreen(controller: controller, strings: strings),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Living room'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Rooms and devices')),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('floor-plan-refresh'))).height,
        greaterThanOrEqualTo(48),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pump();
      expect(find.byKey(const ValueKey('floor-plan-canvas')), findsOneWidget);
      semantics.dispose();
    });
  }
}

final class _Gateway implements FloorPlanGateway {
  _Gateway(this.result);
  final Future<FloorPlanSnapshot> result;
  @override
  Future<FloorPlanSnapshot> read() => result;
}
