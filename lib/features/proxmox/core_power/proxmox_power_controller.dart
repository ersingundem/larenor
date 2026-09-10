import 'package:flutter/foundation.dart';

import 'proxmox_power_models.dart';

abstract interface class ProxmoxPowerGateway {
  Future<PowerPreview> preview(
    ProxmoxPowerTarget target,
    ProxmoxPowerAction action,
  );
  Future<PowerReceipt> confirm(
    ProxmoxPowerTarget target,
    PowerPreview preview, {
    required bool highRiskConfirmed,
  });
  Future<void> cancel(ProxmoxPowerTarget target, PowerPreview preview);
}

enum ProxmoxPowerPhase {
  idle,
  previewing,
  ready,
  confirming,
  succeeded,
  failed,
  cancelled,
  unknown,
}

final class ProxmoxPowerController extends ChangeNotifier {
  ProxmoxPowerController({
    required this.gateway,
    required this.target,
    required this.current,
  });
  final ProxmoxPowerGateway gateway;
  final ProxmoxPowerTarget target;
  final bool Function() current;
  int _epoch = 0;
  bool _disposed = false, highRiskConfirmed = false;
  ProxmoxPowerPhase phase = ProxmoxPowerPhase.idle;
  PowerPreview? previewValue;
  PowerReceipt? receipt;
  String? failure;

  bool get busy =>
      phase == ProxmoxPowerPhase.previewing ||
      phase == ProxmoxPowerPhase.confirming;
  bool get canConfirm =>
      phase == ProxmoxPowerPhase.ready &&
      (previewValue?.requiresSecondConfirmation != true || highRiskConfirmed);

  bool _valid(int operation) => !_disposed && current() && operation == _epoch;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> preview(ProxmoxPowerAction action) async {
    if (_disposed ||
        !current() ||
        phase != ProxmoxPowerPhase.idle ||
        !target.allowedActions.contains(action)) {
      return;
    }
    final operation = ++_epoch;
    phase = ProxmoxPowerPhase.previewing;
    failure = null;
    _emit();
    try {
      final value = await gateway.preview(target, action);
      if (!_valid(operation)) return;
      previewValue = value;
      phase = ProxmoxPowerPhase.ready;
    } catch (_) {
      if (!_valid(operation)) return;
      failure = 'preview_failed';
      phase = ProxmoxPowerPhase.failed;
    }
    _emit();
  }

  void setHighRiskConfirmed(bool value) {
    if (_disposed ||
        phase != ProxmoxPowerPhase.ready ||
        previewValue?.requiresSecondConfirmation != true) {
      return;
    }
    highRiskConfirmed = value;
    _emit();
  }

  Future<void> confirm() async {
    final selected = previewValue;
    if (!canConfirm || selected == null || _disposed || !current()) return;
    final operation = ++_epoch;
    phase = ProxmoxPowerPhase.confirming;
    _emit();
    try {
      final value = await gateway.confirm(
        target,
        selected,
        highRiskConfirmed: highRiskConfirmed,
      );
      if (!_valid(operation)) return;
      receipt = value;
      phase = switch (value.state) {
        ProxmoxPowerReceiptState.succeeded => ProxmoxPowerPhase.succeeded,
        ProxmoxPowerReceiptState.cancelled => ProxmoxPowerPhase.cancelled,
        ProxmoxPowerReceiptState.failed => ProxmoxPowerPhase.failed,
        _ => ProxmoxPowerPhase.unknown,
      };
    } catch (_) {
      if (!_valid(operation)) return;
      failure = 'outcome_unknown';
      phase = ProxmoxPowerPhase.unknown;
    }
    _emit();
  }

  Future<void> cancel() async {
    final selected = previewValue;
    if (_disposed ||
        !current() ||
        phase != ProxmoxPowerPhase.ready ||
        selected == null) {
      return;
    }
    final operation = ++_epoch;
    phase = ProxmoxPowerPhase.confirming;
    _emit();
    try {
      await gateway.cancel(target, selected);
      if (!_valid(operation)) return;
      phase = ProxmoxPowerPhase.cancelled;
    } catch (_) {
      if (!_valid(operation)) return;
      phase = ProxmoxPowerPhase.unknown;
      failure = 'cancel_unknown';
    }
    _emit();
  }

  void invalidate() {
    _epoch++;
    phase = ProxmoxPowerPhase.idle;
    previewValue = null;
    receipt = null;
    highRiskConfirmed = false;
    failure = null;
    _emit();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }
}
