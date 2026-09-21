import 'package:flutter/foundation.dart';

@immutable
final class PowerBudgetAuthority {
  const PowerBudgetAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionId,
    required this.meterId,
    required this.routeId,
    required this.coreRevision,
    required this.homeRevision,
    required this.accountRevision,
    required this.meterRevision,
    required this.tariffRevision,
    required this.loadRegistryRevision,
    required this.gridLimitRevision,
    required this.overrideRevision,
    required this.planRevision,
    required this.clientSessionRevision,
    required this.routeRevision,
    required this.canControl,
  });
  final String coreId, homeId, accountId, sessionId, meterId, routeId;
  final int coreRevision, homeRevision, accountRevision, meterRevision;
  final int tariffRevision, loadRegistryRevision, gridLimitRevision;
  final int overrideRevision,
      planRevision,
      clientSessionRevision,
      routeRevision;
  final bool canControl;

  bool get isBounded =>
      [
        coreId,
        homeId,
        accountId,
        sessionId,
        meterId,
        routeId,
      ].every((value) => value.isNotEmpty) &&
      [
        coreRevision,
        homeRevision,
        accountRevision,
        meterRevision,
        tariffRevision,
        loadRegistryRevision,
        gridLimitRevision,
        overrideRevision,
        planRevision,
      ].every((value) => value > 0) &&
      clientSessionRevision >= 0 &&
      routeRevision >= 0;
}

@immutable
final class PowerBudgetAction {
  const PowerBudgetAction({
    required this.loadId,
    required this.label,
    required this.loadRevision,
    required this.reductionW,
    required this.targetW,
    required this.priority,
  });
  final String loadId, label;
  final int loadRevision, reductionW, targetW, priority;
}

@immutable
final class PowerBudgetSnapshot {
  const PowerBudgetSnapshot({
    required this.authority,
    required this.gridImportW,
    required this.gridLimitW,
    required this.tariffMicrosPerKwh,
    required this.meterStatus,
    required this.tariffStatus,
    required this.planId,
    required this.planHash,
    required this.planStatus,
    required this.requiredReductionW,
    required this.overrideExpiresAtMs,
    required this.controlCapability,
    required this.commandEndpointAvailable,
    required this.actions,
  });
  final PowerBudgetAuthority authority;
  final int gridImportW, gridLimitW, tariffMicrosPerKwh;
  final String meterStatus, tariffStatus, planId, planHash, planStatus;
  final int requiredReductionW;
  final int? overrideExpiresAtMs;
  final String controlCapability;
  final bool commandEndpointAvailable;
  final List<PowerBudgetAction> actions;

  bool get isVerified =>
      authority.isBounded &&
      meterStatus == 'verified' &&
      tariffStatus == 'verified' &&
      !commandEndpointAvailable &&
      const {'read_only', 'manual_required'}.contains(controlCapability);
}
