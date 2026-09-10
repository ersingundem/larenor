import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/proxmox/core_power/proxmox_power_api.dart';
import 'package:larenor/features/proxmox/core_power/proxmox_power_controller.dart';
import 'package:larenor/features/proxmox/core_power/proxmox_power_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const target = ProxmoxPowerTarget(
  coreId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  homeId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  resourceId: 'cccccccccccccccccccccccccccccccc',
  userRevision: 2,
  resourceRevision: 3,
  aclRevision: 4,
  bindingId: 'binding_1',
  bindingRevision: 5,
  serviceId: 'service_1',
  serviceRevision: 6,
  guestKind: ProxmoxGuestKind.qemu,
  currentState: ProxmoxGuestState.running,
  statusRevision: 7,
);

PowerPreview fixturePreview({bool high = true}) => PowerPreview.fromJson({
  'schemaVersion': 1,
  'id': 'dddddddddddddddddddddddddddddddd',
  'requestId': 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
  'action': high ? 'reboot' : 'shutdown',
  'riskClass': high ? 'high' : 'moderate',
  'requiresSecondConfirmation': high,
  'guestKind': 'qemu',
  'currentState': 'running',
  'expectedResultState': high ? 'running' : 'stopped',
  'expiresAt': 1788609660.0,
});

PowerReceipt fixtureReceipt(String state) => PowerReceipt.fromJson({
  'schemaVersion': 1,
  'requestId': 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
  'action': 'reboot',
  'state': state,
  'resultCode': state == 'succeeded' ? 'completed' : 'outcome_uncertain',
  'guestState': 'running',
  'statusRevision': 8,
  'causalityVerified': false,
  'createdAt': 1788609600.0,
  'updatedAt': 1788609601.0,
});

class FakeGateway implements ProxmoxPowerGateway {
  int previews = 0, confirms = 0, cancels = 0;
  Completer<PowerPreview>? pendingPreview;
  Completer<PowerReceipt>? pendingConfirm;
  Object? previewError;

  @override
  Future<PowerPreview> preview(
    ProxmoxPowerTarget target,
    ProxmoxPowerAction action,
  ) {
    previews++;
    if (previewError != null) return Future.error(previewError!);
    return pendingPreview?.future ??
        Future.value(fixturePreview(high: action == ProxmoxPowerAction.reboot));
  }

  @override
  Future<PowerReceipt> confirm(
    ProxmoxPowerTarget target,
    PowerPreview preview, {
    required bool highRiskConfirmed,
  }) {
    confirms++;
    return pendingConfirm?.future ?? Future.value(fixtureReceipt('succeeded'));
  }

  @override
  Future<void> cancel(ProxmoxPowerTarget target, PowerPreview preview) async {
    cancels++;
  }
}

void main() {
  test('Core gateway sends preview, confirm, cancel and result once', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      final body = request.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(request.body) as Map<String, dynamic>;
      final suffix = request.url.path.split('/api/v1').last;
      if (suffix.endsWith('/previews')) {
        return http.Response(
          jsonEncode({
            'preview': {
              ...fixturePreview(high: false).toJson(),
              'requestId': body['requestId'],
              'action': 'shutdown',
            },
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      if (suffix.endsWith('/confirm')) {
        return http.Response(
          jsonEncode({
            'receipt': {
              ...fixtureReceipt('succeeded').toJson(),
              'requestId': body['requestId'],
              'action': 'shutdown',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (suffix.contains('/results/')) {
        return http.Response(
          jsonEncode({'receipt': fixtureReceipt('unknown').toJson()}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'DELETE') return http.Response('', 204);
      throw StateError('unexpected synthetic route');
    });
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.invalid'),
      client: client,
    );
    final gateway = CoreProxmoxPowerApi(
      transport,
      't' * 43,
      random: Random(1),
    );
    final proposed = await gateway.preview(target, ProxmoxPowerAction.shutdown);
    final previewBody = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(requests.single.url.host, 'core.invalid');
    expect(previewBody['expectedStatusRevision'], 7);
    await gateway.confirm(target, proposed, highRiskConfirmed: false);
    await gateway.cancel(target, proposed);
    final receipt = await gateway.result(target, 'e' * 32);
    expect(receipt.state, ProxmoxPowerReceiptState.unknown);
    expect(requests.map((request) => request.method), [
      'POST',
      'POST',
      'DELETE',
      'GET',
    ]);
    transport.close();
  });

  test('strict models reject unknown fields and success-like unknown', () {
    expect(
      () => PowerPreview.fromJson({
        ...fixturePreview().toJson(),
        'host': 'private.invalid',
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => PowerReceipt.fromJson({
        ...fixtureReceipt('unknown').toJson(),
        'resultCode': 'completed',
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => target.copyWith(bindingId: '../node'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('high-risk confirm is explicit and double taps never replay', () async {
    final gateway = FakeGateway();
    final controller = ProxmoxPowerController(
      gateway: gateway,
      target: target,
      current: () => true,
    );
    final one = controller.preview(ProxmoxPowerAction.reboot);
    final two = controller.preview(ProxmoxPowerAction.reboot);
    await Future.wait([one, two]);
    expect(gateway.previews, 1);
    expect(controller.canConfirm, isFalse);
    controller.setHighRiskConfirmed(true);
    final first = controller.confirm();
    final second = controller.confirm();
    await Future.wait([first, second]);
    expect((gateway.previews, gateway.confirms), (1, 1));
    expect(controller.phase, ProxmoxPowerPhase.succeeded);
    controller.dispose();
  });

  test('route, account or PIN invalidation discards every late result', () async {
    final gateway = FakeGateway()..pendingConfirm = Completer<PowerReceipt>();
    var current = true;
    final controller = ProxmoxPowerController(
      gateway: gateway,
      target: target,
      current: () => current,
    );
    await controller.preview(ProxmoxPowerAction.reboot);
    controller.setHighRiskConfirmed(true);
    final future = controller.confirm();
    current = false;
    controller.invalidate();
    gateway.pendingConfirm!.complete(fixtureReceipt('succeeded'));
    await future;
    expect(controller.phase, ProxmoxPowerPhase.idle);
    expect(controller.receipt, isNull);
    expect(gateway.confirms, 1);
    controller.dispose();
  });

  test('failed or unknown operations never retry automatically', () async {
    final gateway = FakeGateway()..previewError = TimeoutException('fixture');
    final controller = ProxmoxPowerController(
      gateway: gateway,
      target: target,
      current: () => true,
    );
    await controller.preview(ProxmoxPowerAction.shutdown);
    expect(controller.phase, ProxmoxPowerPhase.failed);
    await Future<void>.delayed(Duration.zero);
    await controller.preview(ProxmoxPowerAction.shutdown);
    expect(gateway.previews, 1);
    controller.dispose();
  });
}
