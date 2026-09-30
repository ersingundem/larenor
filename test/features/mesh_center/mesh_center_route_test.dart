import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/mesh_center/presentation/mesh_center_management_screen.dart';
import 'package:larenor/features/mesh_center/presentation/mesh_center_route.dart';
import 'package:larenor/features/server/providers/server_providers.dart';

import '../server/server_admin_test_support.dart';

const _serviceId = 'cccccccccccccccccccccccccccccccc';

void main() {
  testWidgets(
    'Thread diagnostics opens and configures when no Zigbee provider exists',
    (tester) async {
      final fixture = AdminFixture()..now = DateTime.now().toUtc();
      addTearDown(fixture.account.dispose);
      var bindingRevision = 0;
      fixture.respond = (request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path.endsWith('/health')) {
          return fixture.json({'service': 'larenor-server', 'apiVersion': 1});
        }
        if (request.method == 'GET' &&
            path.endsWith('/admin/mesh-center/${'a' * 32}/${'b' * 32}')) {
          return fixture.json({
            'error': {'code': 'mesh_provider_unavailable'},
          }, 503);
        }
        if (request.method == 'GET' &&
            path.endsWith('/thread-diagnostics/configuration')) {
          return fixture.json({
            'configuration': {
              'schemaVersion': 1,
              'coreId': 'a' * 32,
              'homeId': 'b' * 32,
              'binding': bindingRevision == 0
                  ? null
                  : {
                      'schemaVersion': 1,
                      'revision': bindingRevision,
                      'coreId': 'a' * 32,
                      'homeId': 'b' * 32,
                      'serviceId': _serviceId,
                      'serviceRevision': 4,
                    },
              'services': const [
                {
                  'schemaVersion': 1,
                  'serviceId': _serviceId,
                  'serviceRevision': 4,
                  'name': 'Home Assistant',
                },
              ],
            },
          });
        }
        if (request.method == 'PUT' &&
            path.endsWith('/thread-diagnostics/configuration')) {
          expect(jsonDecode(request.body), {
            'schemaVersion': 1,
            'expectedRevision': null,
            'serviceId': _serviceId,
            'expectedServiceRevision': 4,
          });
          bindingRevision = 1;
          return fixture.json({
            'binding': {
              'schemaVersion': 1,
              'revision': bindingRevision,
              'coreId': 'a' * 32,
              'homeId': 'b' * 32,
              'serviceId': _serviceId,
              'serviceRevision': 4,
            },
          });
        }
        if (request.method == 'GET' && path.endsWith('/thread-diagnostics')) {
          return fixture.json({
            'diagnostics': {
              'schemaVersion': 1,
              'coreId': 'a' * 32,
              'homeId': 'b' * 32,
              'bindingRevision': bindingRevision,
              'serviceId': _serviceId,
              'serviceRevision': 4,
              'capturedAtMs': fixture.now.millisecondsSinceEpoch,
              'readOnly': true,
              'datasets': const [
                {
                  'schemaVersion': 1,
                  'datasetId': 'dddddddddddddddddddddddddddddddd',
                  'networkName': 'Home Thread',
                  'channel': 15,
                  'preferred': true,
                  'source': 'otbr',
                },
              ],
              'routers': const [
                {
                  'schemaVersion': 1,
                  'routerId': 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
                  'networkName': 'Home Thread',
                  'brand': 'homeassistant',
                  'modelName': 'OTBR',
                  'threadVersion': '1.3.0',
                  'vendorName': 'Home Assistant',
                  'unconfigured': false,
                },
              ],
            },
          });
        }
        return fixture.defaultResponse(request);
      };
      await fixture.account.initialize();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverAccountControllerProvider.overrideWithValue(fixture.account),
          ],
          child: CupertinoApp(home: MeshCenterRoute(gateCurrent: () => true)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(MeshCenterManagementScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('mesh-reload')), findsOneWidget);
      final configure = find.byKey(
        const ValueKey('thread-diagnostics-configure'),
      );
      expect(configure, findsOneWidget);
      await tester.ensureVisible(configure);
      await tester.tap(configure);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('thread-service-$_serviceId')),
      );
      await tester.pumpAndSettle();

      expect(bindingRevision, 1);
      expect(find.textContaining('Home Thread · 15'), findsOneWidget);
      final threadCalls = fixture.calls.where(
        (call) => call.url.path.contains('/thread-diagnostics'),
      );
      expect(threadCalls, hasLength(3));
      expect(
        threadCalls.every(
          (call) =>
              call.headers['authorization'] ==
              'Bearer synthetic_admin_access_12345',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
