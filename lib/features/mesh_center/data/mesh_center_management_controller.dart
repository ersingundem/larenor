import 'package:flutter/foundation.dart';

import '../../server/domain/server_models.dart';
import '../domain/mesh_center_models.dart';
import 'mesh_center_management_api.dart';

enum MeshCenterManagementState {
  idle,
  loading,
  ready,
  awaitingConfirmation,
  busy,
  verified,
  failed,
  stale,
}

final class MeshCenterManagementController extends ChangeNotifier {
  MeshCenterManagementController({
    required this.api,
    required this.authority,
    ThreadDiagnosticsClientAuthority? threadAuthority,
    required this.isCurrent,
    DateTime Function()? clock,
  }) : threadAuthority =
           threadAuthority ??
           (authority == null
               ? null
               : ThreadDiagnosticsClientAuthority.fromMesh(authority)),
       _clock = clock ?? DateTime.now;

  final MeshCenterManagementApi api;
  final MeshClientAuthority? authority;
  final ThreadDiagnosticsClientAuthority? threadAuthority;
  final bool Function() isCurrent;
  final DateTime Function() _clock;
  int _epoch = 0;
  bool _interactive = true;
  bool _disposed = false;

  MeshCenterManagementState state = MeshCenterManagementState.idle;
  MeshCenterSnapshot? snapshot;
  MeshFirmwareUpdatePreview? pendingPreview;
  MeshFirmwareUpdateResult? lastResult;
  MeshManagedOtaPreview? pendingManagedPreview;
  MeshManagedOtaResult? lastManagedResult;
  ThreadDiagnosticsConfiguration? threadConfiguration;
  ThreadDiagnosticsSnapshot? threadDiagnostics;
  bool threadDiagnosticsUnavailable = false;
  bool threadDiagnosticsBusy = false;

  bool _current() {
    if (_disposed ||
        !_interactive ||
        !(authority?.isBounded == true || threadAuthority?.isBounded == true)) {
      return false;
    }
    try {
      return isCurrent();
    } catch (_) {
      return false;
    }
  }

  bool _operationCurrent(int operation) => operation == _epoch && _current();
  bool get canAct => _current() && state != MeshCenterManagementState.busy;
  bool get supportsThreadDiagnostics =>
      api is ThreadDiagnosticsManagementApi &&
      threadAuthority?.isBounded == true;
  bool canUpdateDevice(MeshClientDevice device) =>
      canAct &&
      authority?.admin == true &&
      authority?.canUpdate == true &&
      snapshot?.devices.contains(device) == true &&
      device.canOfferUpdateAt(_clock());

  bool canCheckManagedUpdate(MeshClientDevice device) {
    final now = _clock();
    return canAct &&
        api is ManagedOtaManagementApi &&
        authority?.admin == true &&
        authority?.canUpdate == true &&
        snapshot?.devices.contains(device) == true &&
        device.protocol == MeshProtocol.zigbee &&
        device.reachable &&
        !device.updating &&
        device.lastSeenAt != null &&
        !device.lastSeenAt!.isAfter(now) &&
        now.difference(device.lastSeenAt!) <= const Duration(minutes: 5) &&
        (device.powerSource == MeshPowerSource.mains ||
            device.batteryPercent != null && device.batteryPercent! >= 70);
  }

  void _stale() {
    snapshot = null;
    pendingPreview = null;
    lastResult = null;
    pendingManagedPreview = null;
    lastManagedResult = null;
    threadConfiguration = null;
    threadDiagnostics = null;
    threadDiagnosticsUnavailable = false;
    threadDiagnosticsBusy = false;
    state = MeshCenterManagementState.stale;
    if (!_disposed) notifyListeners();
  }

  void setInteractive(bool value) {
    if (_disposed || value == _interactive) return;
    _interactive = value;
    if (!value) {
      _epoch++;
      _stale();
    }
  }

  Future<void> load() async {
    if (!_current()) {
      _stale();
      return;
    }
    final operation = ++_epoch;
    snapshot = null;
    pendingPreview = null;
    lastResult = null;
    pendingManagedPreview = null;
    lastManagedResult = null;
    threadConfiguration = null;
    threadDiagnostics = null;
    threadDiagnosticsUnavailable = false;
    threadDiagnosticsBusy = false;
    state = MeshCenterManagementState.loading;
    notifyListeners();
    final threadLoad = _loadThreadSupport(operation);
    final meshAuthority = authority;
    if (meshAuthority == null) {
      state = MeshCenterManagementState.failed;
    } else {
      try {
        final response = await api.load(meshAuthority);
        if (!_operationCurrent(operation)) {
          _stale();
          return;
        }
        if (response.authority != meshAuthority ||
            !response.isCoherentAt(_clock())) {
          state = MeshCenterManagementState.failed;
        } else {
          snapshot = response;
          state = MeshCenterManagementState.ready;
        }
      } catch (_) {
        if (!_operationCurrent(operation)) {
          _stale();
          return;
        }
        state = MeshCenterManagementState.failed;
      }
    }
    await threadLoad;
    if (!_operationCurrent(operation)) {
      _stale();
      return;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _loadThreadSupport(int operation) async {
    final authority = threadAuthority;
    if (api is! ThreadDiagnosticsManagementApi || authority == null) return;
    final thread = api as ThreadDiagnosticsManagementApi;
    try {
      final configuration = await thread.loadThreadConfiguration(authority);
      if (!_operationCurrent(operation)) {
        return;
      }
      threadConfiguration = configuration;
      final binding = configuration.binding;
      if (binding == null) return;
      final diagnostics = await thread.loadThreadDiagnostics(authority);
      if (!_operationCurrent(operation)) return;
      final now = _clock();
      if (diagnostics.bindingRevision != binding.revision ||
          diagnostics.serviceId != binding.serviceId ||
          diagnostics.serviceRevision != binding.serviceRevision ||
          diagnostics.capturedAt.isAfter(now) ||
          now.difference(diagnostics.capturedAt) > const Duration(minutes: 5)) {
        throw const LarenorServerException('invalid_response');
      }
      threadDiagnostics = diagnostics;
    } catch (_) {
      if (_operationCurrent(operation)) {
        threadDiagnostics = null;
        threadDiagnosticsUnavailable = true;
      }
    }
  }

  Future<void> configureThreadDiagnostics(ThreadServiceOption service) async {
    final configuration = threadConfiguration;
    final authority = threadAuthority;
    if (api is! ThreadDiagnosticsManagementApi ||
        authority == null ||
        !_current() ||
        configuration == null ||
        threadDiagnosticsBusy ||
        !configuration.services.contains(service)) {
      return;
    }
    final operation = ++_epoch;
    threadDiagnosticsBusy = true;
    threadDiagnosticsUnavailable = false;
    notifyListeners();
    try {
      final thread = api as ThreadDiagnosticsManagementApi;
      final binding = await thread.configureThreadDiagnostics(
        authority,
        service: service,
        expectedRevision: configuration.binding?.revision,
      );
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      threadConfiguration = ThreadDiagnosticsConfiguration(
        binding: binding,
        services: configuration.services,
      );
      final diagnostics = await thread.loadThreadDiagnostics(authority);
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      final now = _clock();
      if (diagnostics.bindingRevision != binding.revision ||
          diagnostics.serviceId != binding.serviceId ||
          diagnostics.serviceRevision != binding.serviceRevision ||
          diagnostics.capturedAt.isAfter(now) ||
          now.difference(diagnostics.capturedAt) > const Duration(minutes: 5)) {
        throw const LarenorServerException('invalid_response');
      }
      threadDiagnostics = diagnostics;
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      threadDiagnostics = null;
      threadDiagnosticsUnavailable = true;
    } finally {
      if (_operationCurrent(operation)) {
        threadDiagnosticsBusy = false;
      }
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> previewUpdate(MeshClientDevice device) async {
    final authority = this.authority;
    final currentSnapshot = snapshot;
    final offer = device.update;
    if (authority == null ||
        !canUpdateDevice(device) ||
        (state != MeshCenterManagementState.ready &&
            state != MeshCenterManagementState.verified) ||
        currentSnapshot == null ||
        !currentSnapshot.devices.contains(device) ||
        offer == null) {
      return;
    }
    final operation = ++_epoch;
    pendingPreview = null;
    lastResult = null;
    state = MeshCenterManagementState.busy;
    notifyListeners();
    try {
      final value = await api.preview(
        authority,
        snapshot: currentSnapshot,
        device: device,
        firmware: offer,
      );
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      if (!value.isExactFor(
        authority,
        currentSnapshot,
        device,
        offer,
        _clock(),
      )) {
        state = MeshCenterManagementState.failed;
      } else {
        pendingPreview = value;
        state = MeshCenterManagementState.awaitingConfirmation;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      state = MeshCenterManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> previewManagedUpdate(MeshClientDevice device) async {
    final authority = this.authority;
    final currentSnapshot = snapshot;
    if (authority == null ||
        api is! ManagedOtaManagementApi ||
        !canCheckManagedUpdate(device) ||
        (state != MeshCenterManagementState.ready &&
            state != MeshCenterManagementState.verified) ||
        currentSnapshot == null ||
        !currentSnapshot.devices.contains(device)) {
      return;
    }
    final managed = api as ManagedOtaManagementApi;
    final operation = ++_epoch;
    pendingPreview = null;
    pendingManagedPreview = null;
    lastResult = null;
    lastManagedResult = null;
    state = MeshCenterManagementState.busy;
    notifyListeners();
    try {
      final availability = await managed.checkManagedOta(
        authority,
        snapshot: currentSnapshot,
        device: device,
      );
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      if (availability.snapshot.authority != authority ||
          !availability.offer.isExactFor(
            availability.snapshot,
            availability.device,
            _clock(),
          )) {
        state = MeshCenterManagementState.failed;
      } else {
        final preview = await managed.previewManagedOta(
          authority,
          availability,
        );
        if (!_operationCurrent(operation)) {
          _stale();
          return;
        }
        if (!preview.isExactFor(availability, _clock())) {
          state = MeshCenterManagementState.failed;
        } else {
          snapshot = availability.snapshot;
          pendingManagedPreview = preview;
          state = MeshCenterManagementState.awaitingConfirmation;
        }
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      state = MeshCenterManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  void cancelPending() {
    if (!_current() ||
        (pendingPreview == null && pendingManagedPreview == null)) {
      return;
    }
    _epoch++;
    pendingPreview = null;
    pendingManagedPreview = null;
    state = MeshCenterManagementState.ready;
    notifyListeners();
  }

  Future<void> confirmPending() async {
    final managedPreview = pendingManagedPreview;
    if (managedPreview != null) {
      await _confirmManagedPending(managedPreview);
      return;
    }
    final authority = this.authority;
    final preview = pendingPreview;
    if (authority == null ||
        !_current() ||
        state != MeshCenterManagementState.awaitingConfirmation ||
        preview == null ||
        !preview.expiresAt.isAfter(_clock())) {
      return;
    }
    final operation = ++_epoch;
    state = MeshCenterManagementState.busy;
    notifyListeners();
    try {
      final receipt = await api.confirm(authority, preview);
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      if (!receipt.isExactFor(preview)) {
        pendingPreview = null;
        state = MeshCenterManagementState.failed;
        notifyListeners();
        return;
      }
      final readback = await api.readback(
        authority,
        requestId: preview.requestId,
      );
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      if (!readback.isExactFor(preview)) {
        pendingPreview = null;
        state = MeshCenterManagementState.failed;
      } else {
        pendingPreview = null;
        lastResult = readback;
        state = MeshCenterManagementState.verified;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      // Delivery is ambiguous. Never repeat a firmware command automatically.
      pendingPreview = null;
      lastResult = null;
      state = MeshCenterManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _confirmManagedPending(MeshManagedOtaPreview preview) async {
    final authority = this.authority;
    if (authority == null ||
        api is! ManagedOtaManagementApi ||
        !_current() ||
        state != MeshCenterManagementState.awaitingConfirmation ||
        !preview.expiresAt.isAfter(_clock())) {
      return;
    }
    final managed = api as ManagedOtaManagementApi;
    final operation = ++_epoch;
    state = MeshCenterManagementState.busy;
    notifyListeners();
    try {
      MeshManagedOtaResult? receipt;
      try {
        receipt = await managed.confirmManagedOta(authority, preview);
      } on LarenorServerException catch (error) {
        // The POST may have reached Core before the 20-second HTTP boundary.
        // Only read the durable record; never send confirm again.
        if (error.code != 'timeout' &&
            error.code != 'connection_failed' &&
            error.code != 'invalid_response') {
          rethrow;
        }
      }
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      if (receipt != null &&
          receipt.status == MeshUpdateStatus.confirmed &&
          !receipt.isExactFor(preview)) {
        pendingManagedPreview = null;
        lastManagedResult = receipt;
        state = MeshCenterManagementState.failed;
        notifyListeners();
        return;
      }
      final readback = await managed.awaitManagedOtaResult(
        authority,
        requestId: preview.requestId,
      );
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      pendingManagedPreview = null;
      lastManagedResult = readback;
      state = readback.isExactFor(preview)
          ? MeshCenterManagementState.verified
          : MeshCenterManagementState.failed;
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      // The persisted dispatch may have reached Zigbee2MQTT. Never auto-retry.
      pendingManagedPreview = null;
      lastManagedResult = null;
      state = MeshCenterManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    snapshot = null;
    pendingPreview = null;
    lastResult = null;
    pendingManagedPreview = null;
    lastManagedResult = null;
    threadConfiguration = null;
    threadDiagnostics = null;
    threadDiagnosticsUnavailable = false;
    threadDiagnosticsBusy = false;
    super.dispose();
  }
}
