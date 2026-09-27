import '../../kiosk/domain/kiosk_remote_view.dart';
import 'managed_tablet_runtime_owner.dart';

/// Locally confirmed app-surface transport for the current managed tablet.
///
/// This port never exposes full-device projection. Frames can only be sent
/// after [KioskRemoteViewController] has accepted the exact route authority,
/// and the MQTT runtime revalidates the pairing before every publication.
final class ManagedTabletAppViewPort implements KioskRemoteViewPort {
  ManagedTabletAppViewPort({required this.owner, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final ManagedTabletRuntimeOwner owner;
  final DateTime Function() _now;
  _ManagedAppViewSession? _active;
  bool _publishing = false;

  @override
  Set<KioskRemoteViewMode> get capabilities => const {
    KioskRemoteViewMode.appSurface,
  };

  String? get activeRequestId => _active?.requestId;

  @override
  Future<KioskRemotePortResult> start(
    KioskRemoteViewMode mode,
    String requestId,
    KioskRemoteViewContext trusted,
  ) async {
    if (mode != KioskRemoteViewMode.appSurface ||
        _active != null ||
        !trusted.binding.valid ||
        !trusted.foreground ||
        !trusted.routeVisible ||
        !trusted.interactionActive ||
        trusted.sensitivity != KioskScreenSensitivity.ordinary) {
      return const KioskRemotePortResult(
        outcome: KioskRemotePortOutcome.rejected,
      );
    }
    final handle = 'app-view-$requestId';
    try {
      await owner.publishRemoteViewReceipt(
        requestId: requestId,
        status: 'active',
        reasonCode: 'local_confirmation_observed',
      );
    } catch (_) {
      return const KioskRemotePortResult(
        outcome: KioskRemotePortOutcome.uncertain,
      );
    }
    _active = _ManagedAppViewSession(
      requestId: requestId,
      handle: handle,
      authority: trusted.binding,
    );
    return KioskRemotePortResult(
      outcome: KioskRemotePortOutcome.accepted,
      receiptHandle: handle,
    );
  }

  @override
  Future<bool> readback(
    String receiptHandle,
    KioskRemoteViewMode mode,
    KioskRemoteViewContext trusted,
  ) async {
    final active = _active;
    return mode == KioskRemoteViewMode.appSurface &&
        active != null &&
        active.handle == receiptHandle &&
        active.authority == trusted.binding &&
        trusted.foreground &&
        trusted.routeVisible &&
        trusted.interactionActive &&
        trusted.sensitivity == KioskScreenSensitivity.ordinary;
  }

  @override
  Future<bool> stop(
    String receiptHandle,
    KioskRemoteViewMode mode,
    KioskRemoteViewContext trusted,
  ) async {
    final active = _active;
    if (mode != KioskRemoteViewMode.appSurface ||
        active == null ||
        active.handle != receiptHandle) {
      return false;
    }
    _active = null;
    _publishing = false;
    try {
      await owner.publishRemoteViewReceipt(
        requestId: active.requestId,
        status: 'retired',
        reasonCode: 'local_view_retired',
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> publishPng(List<int> pngBytes) async {
    final active = _active;
    if (active == null) throw StateError('remote_view_not_active');
    if (_publishing) throw StateError('remote_view_publish_in_progress');
    final capturedAt = _now().toUtc();
    final last = active.lastPublishedAt;
    if (last != null &&
        capturedAt.difference(last) < const Duration(milliseconds: 900)) {
      throw StateError('remote_view_rate_limited');
    }
    if (active.sequence >= 0x7fffffff) {
      throw StateError('remote_view_sequence_exhausted');
    }
    _publishing = true;
    final sequence = active.sequence + 1;
    try {
      await owner.publishRemoteViewFrame(
        requestId: active.requestId,
        sequence: sequence,
        capturedAt: capturedAt,
        pngBytes: pngBytes,
      );
      if (identical(_active, active)) {
        active
          ..sequence = sequence
          ..lastPublishedAt = capturedAt;
      }
    } finally {
      _publishing = false;
    }
  }
}

final class _ManagedAppViewSession {
  _ManagedAppViewSession({
    required this.requestId,
    required this.handle,
    required this.authority,
  });

  final String requestId, handle;
  final KioskDeviceAuthority authority;
  int sequence = 0;
  DateTime? lastPublishedAt;
}
