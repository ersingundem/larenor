import 'dart:math';

import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import 'proxmox_power_controller.dart';
import 'proxmox_power_models.dart';

final class CoreProxmoxPowerApi implements ProxmoxPowerGateway {
  CoreProxmoxPowerApi(this.api, this.accessToken, {Random? random})
    : _random = random ?? Random.secure();
  final LarenorServerApi api;
  final String accessToken;
  final Random _random;

  String _id() =>
      List.generate(32, (_) => _random.nextInt(16).toRadixString(16)).join();
  String _base(ProxmoxPowerTarget target) =>
      '/admin/proxmox-power/${target.coreId}/${target.homeId}/${target.resourceId}';

  @override
  Future<PowerPreview> preview(
    ProxmoxPowerTarget target,
    ProxmoxPowerAction action,
  ) async {
    target.validate();
    final requestId = _id();
    final response = await api.request(
      'POST',
      '${_base(target)}/previews',
      token: accessToken,
      body: {
        'schemaVersion': 1,
        'requestId': requestId,
        'action': action.name,
        'expectedUserRevision': target.userRevision,
        'expectedResourceRevision': target.resourceRevision,
        'expectedAclRevision': target.aclRevision,
        'expectedBindingId': target.bindingId,
        'expectedBindingRevision': target.bindingRevision,
        'expectedServiceId': target.serviceId,
        'expectedServiceRevision': target.serviceRevision,
        'expectedGuestKind': target.guestKind.name,
        'expectedCurrentState': target.currentState.name,
        'expectedStatusRevision': target.statusRevision,
      },
    );
    final preview = PowerPreview.fromJson(serverObject(response)['preview']);
    if (preview.requestId != requestId ||
        preview.action != action ||
        preview.guestKind != target.guestKind ||
        preview.currentState != target.currentState) {
      throw const LarenorServerException('invalid_response');
    }
    return preview;
  }

  @override
  Future<PowerReceipt> confirm(
    ProxmoxPowerTarget target,
    PowerPreview preview, {
    required bool highRiskConfirmed,
  }) async {
    final response = await api.request(
      'POST',
      '${_base(target)}/previews/${preview.id}/confirm',
      token: accessToken,
      body: {
        'schemaVersion': 1,
        'requestId': preview.requestId,
        'highRiskConfirmed': highRiskConfirmed,
        'deadlineMs': 5000,
      },
    );
    final receipt = PowerReceipt.fromJson(serverObject(response)['receipt']);
    if (receipt.requestId != preview.requestId ||
        receipt.action != preview.action) {
      throw const LarenorServerException('invalid_response');
    }
    return receipt;
  }

  @override
  Future<void> cancel(ProxmoxPowerTarget target, PowerPreview preview) =>
      api.request(
        'DELETE',
        '${_base(target)}/previews/${preview.id}',
        token: accessToken,
        allowEmpty: true,
      );

  /// Reads the one receipt explicitly requested by the caller. This is never
  /// polled or used to retry an outcome whose delivery was interrupted.
  Future<PowerReceipt> result(
    ProxmoxPowerTarget target,
    String requestId,
  ) async {
    target.validate();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      throw const LarenorServerException('invalid_request');
    }
    final response = await api.request(
      'GET',
      '${_base(target)}/results/$requestId',
      token: accessToken,
    );
    final receipt = PowerReceipt.fromJson(serverObject(response)['receipt']);
    if (receipt.requestId != requestId) {
      throw const LarenorServerException('invalid_response');
    }
    return receipt;
  }
}
