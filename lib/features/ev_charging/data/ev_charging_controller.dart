import 'package:flutter/foundation.dart';

import '../domain/ev_charging_models.dart';

enum EvChargingFailure { unavailable, stale, invalid }

final class EvChargingController extends ChangeNotifier {
  EvChargingController({
    required this.gateway,
    required this.isCurrent,
    required this.id,
    required this.now,
  });
  final EvChargingGateway gateway;
  final bool Function() isCurrent;
  final String Function() id;
  final DateTime Function() now;
  EvChargeCapability? capabilityValue;
  EvChargePlan? plan;
  EvChargeReceipt? receipt;
  EvChargingFailure? failure;
  bool busy = false, retired = false;
  int epoch = 0;
  bool get current {
    try {
      return !retired && isCurrent();
    } catch (_) {
      return false;
    }
  }

  Future<void> refresh() async {
    if (busy || !current) return;
    final operation = ++epoch;
    busy = true;
    failure = null;
    plan = null;
    notifyListeners();
    try {
      final value = await gateway.capability();
      if (operation != epoch || !current) {
        if (!retired) failure = EvChargingFailure.stale;
        return;
      }
      capabilityValue = value;
    } catch (_) {
      if (operation == epoch && current) {
        failure = EvChargingFailure.unavailable;
      }
    } finally {
      if (operation == epoch && !retired) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> preview(
    EvChargerCapability charger,
    int targetSoc,
    int hours,
  ) async {
    if (busy ||
        !current ||
        targetSoc <= charger.currentSoc ||
        targetSoc > 100 ||
        capabilityValue?.canPlan != true) {
      return;
    }
    final operation = ++epoch;
    busy = true;
    failure = null;
    plan = null;
    receipt = null;
    notifyListeners();
    try {
      final value = await gateway.preview(
        charger: charger,
        previewId: id(),
        departure: now().toUtc().add(Duration(hours: hours)),
        targetSoc: targetSoc,
      );
      if (operation != epoch ||
          !current ||
          value.chargerId != charger.id ||
          value.chargerRevision != charger.chargerRevision ||
          value.scheduleRevision != charger.scheduleRevision) {
        if (!retired) failure = EvChargingFailure.stale;
        return;
      }
      plan = value;
    } catch (_) {
      if (operation == epoch && current) {
        failure = EvChargingFailure.unavailable;
      }
    } finally {
      if (operation == epoch && !retired) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> confirm() async {
    final value = plan;
    if (busy ||
        !current ||
        value == null ||
        value.status != 'ready' ||
        capabilityValue?.canControl != true) {
      return;
    }
    final operation = ++epoch;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final result = await gateway.confirm(value, id());
      if (operation != epoch ||
          !current ||
          result.previewId != value.previewId ||
          result.planHash != value.planHash) {
        if (!retired) failure = EvChargingFailure.stale;
        return;
      }
      receipt = result;
    } catch (_) {
      if (operation == epoch && current) {
        failure = EvChargingFailure.unavailable;
      }
    } finally {
      if (operation == epoch && !retired) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void discardPlan() {
    if (busy || plan == null || !current) return;
    epoch++;
    plan = null;
    receipt = null;
    notifyListeners();
  }

  void retire() {
    if (retired) return;
    retired = true;
    epoch++;
    busy = false;
    plan = null;
    gateway.retire();
  }

  @override
  void dispose() {
    retire();
    super.dispose();
  }
}
