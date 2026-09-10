import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/proxmox/core_power/proxmox_power_discovery.dart';
import 'package:larenor/features/proxmox/core_power/proxmox_power_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const coreId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const homeId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const resourceId = 'cccccccccccccccccccccccccccccccc';
const bindingId = 'dddddddddddddddddddddddddddddddd';
const serviceId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

final context = ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': coreId,
  'homeId': homeId,
});

final resource = HomeResourceRecord.fromJson({
  'ref': {
    'schemaVersion': 1,
    'coreId': coreId,
    'homeId': homeId,
    'kind': 'resource',
    'id': resourceId,
  },
  'label': 'Living room VM',
  'order': 1,
  'revision': 3,
  'aclRevision': 4,
  'permissions': {'read': true, 'write': true},
}, expectedContext: context);

Map<String, Object?> targetJson({
  String targetId = 'ffffffffffffffffffffffffffffffff',
  String state = 'running',
  bool ready = true,
}) => {
  'schemaVersion': 1,
  'targetId': targetId,
  'installationId': serviceId,
  'node': 'pve-a',
  'guestKind': 'qemu',
  'guestId': 101,
  'currentState': state,
  'statusRevision': 7,
  'allowedCommands': ready
      ? state == 'running'
            ? ['shutdown', 'stop', 'reboot', 'reset', 'suspend']
            : state == 'stopped'
            ? ['start']
            : ['resume']
      : <String>[],
  'capabilityReady': ready,
};

Map<String, Object?> pageJson({
  List<Map<String, Object?>>? targets,
  String? nextAfter,
}) => {
  'schemaVersion': 1,
  'scope': {'schemaVersion': 1, 'coreId': coreId, 'homeId': homeId},
  'resourceId': resourceId,
  'userRevision': 2,
  'resourceRevision': 3,
  'aclRevision': 4,
  'bindingId': bindingId,
  'bindingRevision': 5,
  'serviceId': serviceId,
  'serviceRevision': 6,
  'snapshot': '1' * 64,
  'targets': targets ?? [targetJson()],
  'nextAfter': nextAfter,
};

final class FakeDiscoveryGateway implements ProxmoxTargetDiscoveryGateway {
  FakeDiscoveryGateway(this.result);
  ProxmoxTargetDiscoveryResult result;
  Object? error;
  Completer<ProxmoxTargetDiscoveryResult>? pending;
  int requests = 0;

  @override
  Future<ProxmoxTargetDiscoveryResult> discover(HomeResourceRecord resource) {
    requests++;
    if (error case final value?) return Future.error(value);
    return pending?.future ?? Future.value(result);
  }
}

Widget app(Widget child, {double scale = 1}) => CupertinoApp(
  supportedLocales: const [Locale('en'), Locale('tr')],
  localizationsDelegates: GlobalCupertinoLocalizations.delegates,
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: CupertinoPageScaffold(child: child),
  ),
);

void main() {
  test(
    'discovery API binds one exact ready target and uses a bounded read',
    () async {
      late http.Request request;
      final transport = LarenorServerApi(
        endpoint: ServerEndpoint('https://core.invalid'),
        client: MockClient((value) async {
          request = value;
          return http.Response(
            jsonEncode(pageJson()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final result = await CoreProxmoxTargetDiscoveryApi(
        transport,
        't' * 43,
      ).discover(resource);
      expect(request.method, 'GET');
      expect(
        request.url.path,
        '/api/v1/admin/proxmox-power/$coreId/$homeId/$resourceId/targets',
      );
      expect(request.url.queryParameters, {'limit': '2'});
      expect(request.headers['authorization'], 'Bearer ${'t' * 43}');
      expect(result.phase, ProxmoxTargetDiscoveryPhase.ready);
      expect(result.target!.statusRevision, 7);
      expect(result.target!.allowedActions, {
        ProxmoxPowerAction.shutdown,
        ProxmoxPowerAction.stop,
        ProxmoxPowerAction.reboot,
        ProxmoxPowerAction.reset,
        ProxmoxPowerAction.suspend,
      });
      transport.close();
    },
  );

  test(
    'strict discovery rejects revision drift, extra fields and false readiness',
    () {
      expect(
        () => ProxmoxTargetDiscoveryResult.fromJson({
          ...pageJson(),
          'host': 'secret.invalid',
        }, expectedResource: resource),
        throwsA(isA<LarenorServerException>()),
      );
      expect(
        () => ProxmoxTargetDiscoveryResult.fromJson({
          ...pageJson(),
          'resourceRevision': 99,
        }, expectedResource: resource),
        throwsA(
          isA<LarenorServerException>().having(
            (value) => value.code,
            'code',
            'revision_conflict',
          ),
        ),
      );
      expect(
        () => ProxmoxTargetDiscoveryResult.fromJson(
          pageJson(
            targets: [
              {...targetJson(), 'capabilityReady': false},
            ],
          ),
          expectedResource: resource,
        ),
        throwsA(isA<LarenorServerException>()),
      );
    },
  );

  test(
    'multiple, paged and unavailable targets never become command authority',
    () {
      final multiple = ProxmoxTargetDiscoveryResult.fromJson(
        pageJson(
          targets: [
            targetJson(targetId: '1' * 32, ready: false),
            targetJson(targetId: '2' * 32, ready: false),
          ],
        ),
        expectedResource: resource,
      );
      final paged = ProxmoxTargetDiscoveryResult.fromJson(
        pageJson(targets: [targetJson(ready: false)], nextAfter: 'f' * 32),
        expectedResource: resource,
      );
      final unavailable = ProxmoxTargetDiscoveryResult.fromJson(
        pageJson(targets: [targetJson(state: 'unavailable', ready: false)]),
        expectedResource: resource,
      );
      expect(multiple.phase, ProxmoxTargetDiscoveryPhase.ambiguous);
      expect(paged.phase, ProxmoxTargetDiscoveryPhase.ambiguous);
      expect(unavailable.phase, ProxmoxTargetDiscoveryPhase.unavailable);
      expect([
        multiple.target,
        paged.target,
        unavailable.target,
      ], everyElement(isNull));
    },
  );

  test(
    'controller discards late authority and never retries automatically',
    () async {
      final ready = ProxmoxTargetDiscoveryResult.fromJson(
        pageJson(),
        expectedResource: resource,
      );
      final gateway = FakeDiscoveryGateway(ready)
        ..pending = Completer<ProxmoxTargetDiscoveryResult>();
      var current = true;
      final controller = ProxmoxTargetDiscoveryController(
        gateway: gateway,
        resource: resource,
        current: () => current,
      );
      final operation = controller.discover();
      current = false;
      controller.invalidate();
      gateway.pending!.complete(ready);
      await operation;
      expect(controller.phase, ProxmoxTargetDiscoveryPhase.idle);
      expect(controller.target, isNull);
      expect(gateway.requests, 1);
      await Future<void>.delayed(Duration.zero);
      expect(gateway.requests, 1);
      controller.dispose();
    },
  );

  testWidgets('single ready discovery enables explicit 48dp keyboard entry', (
    tester,
  ) async {
    final gateway = FakeDiscoveryGateway(
      ProxmoxTargetDiscoveryResult.fromJson(
        pageJson(),
        expectedResource: resource,
      ),
    );
    final controller = ProxmoxTargetDiscoveryController(
      gateway: gateway,
      resource: resource,
      current: () => true,
    );
    var opened = 0;
    final semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      app(
        ProxmoxTargetDiscoveryEntry(
          controller: controller,
          isAdmin: true,
          canWrite: true,
          onOpen: (_) => opened++,
        ),
        scale: 2,
      ),
    );
    await tester.pump();
    expect(gateway.requests, 1);
    final open = find.byKey(const ValueKey('core-proxmox-power-open'));
    expect(tester.getSize(open).height, greaterThanOrEqualTo(48));
    expect(find.bySemanticsLabel('Open power controls'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, 1);
    semantics.dispose();
    controller.dispose();
  });

  testWidgets('ambiguous, stale, offline and unavailable stay mutation-free', (
    tester,
  ) async {
    final ambiguous = ProxmoxTargetDiscoveryResult.fromJson(
      pageJson(
        targets: [
          targetJson(targetId: '1' * 32, ready: false),
          targetJson(targetId: '2' * 32, ready: false),
        ],
      ),
      expectedResource: resource,
    );
    final gateway = FakeDiscoveryGateway(ambiguous);
    final controller = ProxmoxTargetDiscoveryController(
      gateway: gateway,
      resource: resource,
      current: () => true,
    );
    var opened = 0;
    await tester.pumpWidget(
      app(
        ProxmoxTargetDiscoveryEntry(
          controller: controller,
          isAdmin: true,
          canWrite: true,
          onOpen: (_) => opened++,
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Multiple guests'), findsOneWidget);
    expect(opened, 0);
    gateway.error = const LarenorServerException('server_error');
    await tester.tap(find.byKey(const ValueKey('core-proxmox-power-refresh')));
    await tester.pump();
    expect(find.textContaining('offline'), findsOneWidget);
    expect(gateway.requests, 2);
    gateway.error = const LarenorServerException('revision_conflict');
    await tester.tap(find.byKey(const ValueKey('core-proxmox-power-refresh')));
    await tester.pump();
    expect(find.textContaining('changed'), findsOneWidget);
    gateway
      ..error = null
      ..result = ProxmoxTargetDiscoveryResult.fromJson(
        pageJson(targets: [targetJson(state: 'unavailable', ready: false)]),
        expectedResource: resource,
      );
    await tester.tap(find.byKey(const ValueKey('core-proxmox-power-refresh')));
    await tester.pump();
    expect(find.textContaining('No command-ready'), findsOneWidget);
    expect(gateway.requests, 4);
    await tester.pump(const Duration(seconds: 30));
    expect(gateway.requests, 4);
    expect(opened, 0);
    controller.dispose();
  });

  testWidgets(
    'member never discovers and background invalidates pending read',
    (tester) async {
      final ready = ProxmoxTargetDiscoveryResult.fromJson(
        pageJson(),
        expectedResource: resource,
      );
      final gateway = FakeDiscoveryGateway(ready)
        ..pending = Completer<ProxmoxTargetDiscoveryResult>();
      final controller = ProxmoxTargetDiscoveryController(
        gateway: gateway,
        resource: resource,
        current: () => true,
      );
      await tester.pumpWidget(
        app(
          ProxmoxTargetDiscoveryEntry(
            controller: controller,
            isAdmin: false,
            canWrite: true,
            onOpen: (_) {},
          ),
        ),
      );
      expect(gateway.requests, 0);
      await tester.pumpWidget(
        app(
          ProxmoxTargetDiscoveryEntry(
            controller: controller,
            isAdmin: true,
            canWrite: true,
            onOpen: (_) {},
          ),
        ),
      );
      expect(gateway.requests, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      gateway.pending!.complete(ready);
      await tester.pump();
      expect(controller.target, isNull);
      expect(controller.phase, ProxmoxTargetDiscoveryPhase.idle);
      controller.dispose();
    },
  );
}
