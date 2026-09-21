import 'dart:async';

import 'package:flutter/foundation.dart';

final _identifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
final _requestId = RegExp(r'^[0-9a-f]{32}$');
final _receiptHandle = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
final _appVersion = RegExp(r'^[0-9A-Za-z][0-9A-Za-z.+-]{0,63}$');
const _maxRevision = 0x7fffffff;
const _maxRequestIds = 256;

@immutable
final class KioskDeviceAuthority {
  const KioskDeviceAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.deviceId,
    required this.deviceRevision,
    required this.policyRevision,
    required this.sessionEpoch,
    required this.routeEpoch,
    required this.lifecycleEpoch,
  });

  final String coreId, homeId, accountId, deviceId;
  final int deviceRevision,
      policyRevision,
      sessionEpoch,
      routeEpoch,
      lifecycleEpoch;

  bool get valid =>
      _identifier.hasMatch(coreId) &&
      _identifier.hasMatch(homeId) &&
      _identifier.hasMatch(accountId) &&
      _identifier.hasMatch(deviceId) &&
      _revision(deviceRevision) &&
      _revision(policyRevision) &&
      _revision(sessionEpoch) &&
      _revision(routeEpoch) &&
      _revision(lifecycleEpoch);

  @override
  bool operator ==(Object other) =>
      other is KioskDeviceAuthority &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      deviceId == other.deviceId &&
      deviceRevision == other.deviceRevision &&
      policyRevision == other.policyRevision &&
      sessionEpoch == other.sessionEpoch &&
      routeEpoch == other.routeEpoch &&
      lifecycleEpoch == other.lifecycleEpoch;

  @override
  int get hashCode => Object.hash(
    coreId,
    homeId,
    accountId,
    deviceId,
    deviceRevision,
    policyRevision,
    sessionEpoch,
    routeEpoch,
    lifecycleEpoch,
  );

  @override
  String toString() => 'KioskDeviceAuthority(redacted)';
}

enum KioskNetworkClass { offline, wifi, ethernet, cellular, other }

@immutable
final class KioskDeviceSnapshot {
  const KioskDeviceSnapshot._({
    required this.authority,
    required this.sampleRevision,
    required this.capturedAtElapsedMs,
    required this.batteryPercent,
    required this.charging,
    required this.network,
    required this.appVersion,
    required this.appBuild,
    required this.memoryUsedMb,
    required this.memoryLimitMb,
    required this.processUptimeSeconds,
  });

  final KioskDeviceAuthority authority;
  final int sampleRevision, capturedAtElapsedMs;
  final int? batteryPercent;
  final bool? charging;
  final KioskNetworkClass network;
  final String appVersion;
  final int appBuild, memoryUsedMb, memoryLimitMb, processUptimeSeconds;

  factory KioskDeviceSnapshot.fromChannel(
    Object? raw, {
    required KioskDeviceAuthority expected,
    required bool Function() isCurrent,
    required int nowElapsedMs,
    Duration maxAge = const Duration(seconds: 30),
  }) {
    Never invalid() => throw const FormatException('device_snapshot_invalid');
    if (!expected.valid ||
        raw is! Map ||
        nowElapsedMs < 0 ||
        maxAge <= Duration.zero ||
        maxAge > const Duration(minutes: 5)) {
      invalid();
    }
    final value = <String, Object?>{};
    for (final entry in raw.entries) {
      if (entry.key is! String) invalid();
      value[entry.key! as String] = entry.value;
    }
    const keys = {
      'schemaVersion',
      'deviceId',
      'deviceRevision',
      'policyRevision',
      'sampleRevision',
      'capturedAtElapsedMs',
      'batteryPercent',
      'charging',
      'network',
      'appVersion',
      'appBuild',
      'memoryUsedMb',
      'memoryLimitMb',
      'processUptimeSeconds',
    };
    if (value.length != keys.length ||
        !value.keys.every(keys.contains) ||
        value['schemaVersion'] != 1 ||
        value['deviceId'] != expected.deviceId ||
        value['deviceRevision'] != expected.deviceRevision ||
        value['policyRevision'] != expected.policyRevision) {
      invalid();
    }
    try {
      if (!isCurrent()) invalid();
    } catch (_) {
      invalid();
    }
    final sampleRevision = value['sampleRevision'];
    final capturedAt = value['capturedAtElapsedMs'];
    final battery = value['batteryPercent'];
    final charging = value['charging'];
    final networkName = value['network'];
    final version = value['appVersion'];
    final build = value['appBuild'];
    final used = value['memoryUsedMb'];
    final limit = value['memoryLimitMb'];
    final uptime = value['processUptimeSeconds'];
    final network = KioskNetworkClass.values
        .where((candidate) => candidate.name == networkName)
        .firstOrNull;
    if (sampleRevision is! int ||
        !_revision(sampleRevision) ||
        capturedAt is! int ||
        capturedAt < 0 ||
        capturedAt > 0x1fffffffffffff ||
        capturedAt > nowElapsedMs ||
        nowElapsedMs - capturedAt > maxAge.inMilliseconds ||
        (battery != null &&
            (battery is! int || battery < 0 || battery > 100)) ||
        (charging != null && charging is! bool) ||
        (battery == null) != (charging == null) ||
        network == null ||
        version is! String ||
        !_appVersion.hasMatch(version) ||
        build is! int ||
        !_revision(build) ||
        used is! int ||
        used < 0 ||
        limit is! int ||
        limit < 1 ||
        limit > 1024 * 1024 ||
        used > limit ||
        uptime is! int ||
        uptime < 0 ||
        uptime > 0x1fffffffffffff) {
      invalid();
    }
    return KioskDeviceSnapshot._(
      authority: expected,
      sampleRevision: sampleRevision,
      capturedAtElapsedMs: capturedAt,
      batteryPercent: battery as int?,
      charging: charging as bool?,
      network: network,
      appVersion: version,
      appBuild: build,
      memoryUsedMb: used,
      memoryLimitMb: limit,
      processUptimeSeconds: uptime,
    );
  }

  Map<String, Object?> toPublicJson() => {
    'schemaVersion': 1,
    'sampleRevision': sampleRevision,
    'capturedAtElapsedMs': capturedAtElapsedMs,
    'batteryPercent': batteryPercent,
    'charging': charging,
    'network': network.name,
    'appVersion': appVersion,
    'appBuild': appBuild,
    'memoryUsedMb': memoryUsedMb,
    'memoryLimitMb': memoryLimitMb,
    'processUptimeSeconds': processUptimeSeconds,
  };

  @override
  String toString() => 'KioskDeviceSnapshot(redacted)';
}

enum KioskRemoteViewMode { appSurface, fullDeviceProjection }

enum KioskScreenSensitivity { ordinary, pin, credentials, secret, unknown }

enum KioskRemoteViewStatus {
  denied,
  needsConfirmation,
  active,
  retired,
  unconfirmed,
  unsupported,
}

enum KioskRemotePortOutcome { accepted, rejected, unsupported, uncertain }

@immutable
final class KioskRemoteViewContext {
  const KioskRemoteViewContext({
    required this.binding,
    required this.foreground,
    required this.routeVisible,
    required this.interactionActive,
    required this.sensitivity,
    required this.projectionConsentActive,
    required this.projectionConsentRevision,
  });

  final KioskDeviceAuthority binding;
  final bool foreground, routeVisible, interactionActive;
  final KioskScreenSensitivity sensitivity;
  final bool projectionConsentActive;
  final int? projectionConsentRevision;
}

@immutable
final class KioskRemotePortResult {
  const KioskRemotePortResult({required this.outcome, this.receiptHandle});

  final KioskRemotePortOutcome outcome;
  final String? receiptHandle;

  bool get valid => switch (outcome) {
    KioskRemotePortOutcome.accepted =>
      receiptHandle != null && _receiptHandle.hasMatch(receiptHandle!),
    _ => receiptHandle == null,
  };
}

abstract interface class KioskRemoteViewPort {
  Set<KioskRemoteViewMode> get capabilities;

  Future<KioskRemotePortResult> start(
    KioskRemoteViewMode mode,
    String requestId,
    KioskRemoteViewContext trusted,
  );

  Future<bool> readback(
    String receiptHandle,
    KioskRemoteViewMode mode,
    KioskRemoteViewContext trusted,
  );

  Future<bool> stop(
    String receiptHandle,
    KioskRemoteViewMode mode,
    KioskRemoteViewContext trusted,
  );
}

final class UnsupportedKioskRemoteViewPort implements KioskRemoteViewPort {
  const UnsupportedKioskRemoteViewPort();

  @override
  Set<KioskRemoteViewMode> get capabilities => const {};

  @override
  Future<KioskRemotePortResult> start(
    KioskRemoteViewMode mode,
    String requestId,
    KioskRemoteViewContext trusted,
  ) async =>
      const KioskRemotePortResult(outcome: KioskRemotePortOutcome.unsupported);

  @override
  Future<bool> readback(
    String receiptHandle,
    KioskRemoteViewMode mode,
    KioskRemoteViewContext trusted,
  ) async => false;

  @override
  Future<bool> stop(
    String receiptHandle,
    KioskRemoteViewMode mode,
    KioskRemoteViewContext trusted,
  ) async => false;
}

@immutable
final class KioskRemoteViewPreview {
  const KioskRemoteViewPreview._({
    required this.status,
    this.requestId,
    this.mode,
    this.consentRevision,
    this.generation,
  });

  const KioskRemoteViewPreview.denied()
    : status = KioskRemoteViewStatus.denied,
      requestId = null,
      mode = null,
      consentRevision = null,
      generation = null;

  final KioskRemoteViewStatus status;
  final String? requestId;
  final KioskRemoteViewMode? mode;
  final int? consentRevision, generation;
}

@immutable
final class KioskRemoteViewReceipt {
  const KioskRemoteViewReceipt({
    required this.requestId,
    required this.mode,
    required this.status,
    required this.reasonCode,
  });

  final String requestId;
  final KioskRemoteViewMode mode;
  final KioskRemoteViewStatus status;
  final String reasonCode;

  Map<String, Object?> toPublicJson() => {
    'schemaVersion': 1,
    'requestId': requestId,
    'mode': mode.name,
    'status': status.name,
    'reasonCode': reasonCode,
  };
}

typedef KioskRemoteRequestIdFactory = String Function();

final class KioskRemoteViewController {
  KioskRemoteViewController({
    required this.port,
    required this.isCurrent,
    required this.requestIds,
    DateTime Function()? now,
    Duration previewTtl = const Duration(seconds: 30),
    Duration portTimeout = const Duration(seconds: 10),
  }) : _now = now ?? DateTime.now,
       _previewTtl = previewTtl,
       _portTimeout = portTimeout {
    if (portTimeout <= Duration.zero ||
        portTimeout > const Duration(seconds: 30) ||
        previewTtl <= Duration.zero ||
        previewTtl > const Duration(minutes: 2)) {
      throw ArgumentError.value(portTimeout, 'portTimeout');
    }
  }

  final KioskRemoteViewPort port;
  final bool Function(KioskDeviceAuthority) isCurrent;
  final KioskRemoteRequestIdFactory requestIds;
  final DateTime Function() _now;
  final Duration _previewTtl;
  final Duration _portTimeout;
  final Set<String> _seen = {};
  _RemoteRecord? _record;
  _ActiveRemote? _active;
  int _generation = 0;

  KioskRemoteViewPreview prepare(
    KioskRemoteViewMode mode,
    KioskRemoteViewContext trusted,
  ) {
    if (_record != null ||
        _active != null ||
        _seen.length >= _maxRequestIds ||
        !_allowed(mode, trusted)) {
      return const KioskRemoteViewPreview.denied();
    }
    final String requestId;
    try {
      requestId = requestIds();
    } catch (_) {
      return const KioskRemoteViewPreview.denied();
    }
    if (!_requestId.hasMatch(requestId) || !_seen.add(requestId)) {
      return const KioskRemoteViewPreview.denied();
    }
    _generation++;
    final supported = _capabilities().contains(mode);
    final preview = KioskRemoteViewPreview._(
      status: supported
          ? KioskRemoteViewStatus.needsConfirmation
          : KioskRemoteViewStatus.unsupported,
      requestId: requestId,
      mode: mode,
      consentRevision: mode == KioskRemoteViewMode.fullDeviceProjection
          ? trusted.projectionConsentRevision
          : null,
      generation: _generation,
    );
    _record = _RemoteRecord(
      requestId: requestId,
      mode: mode,
      binding: trusted.binding,
      consentRevision: preview.consentRevision,
      generation: _generation,
      expiresAt: _now().add(_previewTtl),
      unsupported: !supported,
    );
    return preview;
  }

  Future<KioskRemoteViewReceipt> confirm(
    KioskRemoteViewPreview preview,
    KioskRemoteViewContext trusted,
  ) async {
    final record = _record;
    if (record == null ||
        preview.status != KioskRemoteViewStatus.needsConfirmation ||
        preview.requestId != record.requestId ||
        preview.mode != record.mode ||
        preview.generation != record.generation ||
        record.generation != _generation ||
        trusted.binding != record.binding ||
        !_allowed(record.mode, trusted) ||
        (record.mode == KioskRemoteViewMode.fullDeviceProjection &&
            trusted.projectionConsentRevision != record.consentRevision)) {
      return _receipt(record, KioskRemoteViewStatus.denied, 'authority_denied');
    }
    if (record.receipt != null) return record.receipt!;
    if (!record.expiresAt.isAfter(_now())) {
      return record.receipt = _receipt(
        record,
        KioskRemoteViewStatus.denied,
        'preview_expired',
      );
    }
    if (record.unsupported) {
      return record.receipt = _receipt(
        record,
        KioskRemoteViewStatus.unsupported,
        'capability_unavailable',
      );
    }
    if (record.dispatching) {
      return _receipt(
        record,
        KioskRemoteViewStatus.unconfirmed,
        'start_in_progress',
      );
    }
    record.dispatching = true;
    try {
      final started = await port
          .start(record.mode, record.requestId, trusted)
          .timeout(_portTimeout);
      if (!started.valid) {
        return record.receipt = _receipt(
          record,
          KioskRemoteViewStatus.unconfirmed,
          'start_unconfirmed',
        );
      }
      if (started.outcome == KioskRemotePortOutcome.accepted &&
          (record.generation != _generation ||
              !record.expiresAt.isAfter(_now()) ||
              trusted.binding != record.binding ||
              !_allowed(record.mode, trusted))) {
        await _compensate(started.receiptHandle!, record.mode, trusted);
        return record.receipt = _receipt(
          record,
          KioskRemoteViewStatus.unconfirmed,
          'start_unconfirmed',
        );
      }
      if (record.generation != _generation ||
          trusted.binding != record.binding ||
          !_allowed(record.mode, trusted)) {
        return record.receipt = _receipt(
          record,
          KioskRemoteViewStatus.unconfirmed,
          'start_unconfirmed',
        );
      }
      switch (started.outcome) {
        case KioskRemotePortOutcome.rejected:
          return record.receipt = _receipt(
            record,
            KioskRemoteViewStatus.denied,
            'native_rejected',
          );
        case KioskRemotePortOutcome.unsupported:
          return record.receipt = _receipt(
            record,
            KioskRemoteViewStatus.unsupported,
            'capability_unavailable',
          );
        case KioskRemotePortOutcome.uncertain:
          return record.receipt = _receipt(
            record,
            KioskRemoteViewStatus.unconfirmed,
            'start_unconfirmed',
          );
        case KioskRemotePortOutcome.accepted:
          late final bool observed;
          try {
            observed = await port
                .readback(started.receiptHandle!, record.mode, trusted)
                .timeout(_portTimeout);
          } catch (_) {
            await _compensate(started.receiptHandle!, record.mode, trusted);
            return record.receipt = _receipt(
              record,
              KioskRemoteViewStatus.unconfirmed,
              'start_unconfirmed',
            );
          }
          if (!observed ||
              record.generation != _generation ||
              trusted.binding != record.binding ||
              !_allowed(record.mode, trusted)) {
            await _compensate(started.receiptHandle!, record.mode, trusted);
            return record.receipt = _receipt(
              record,
              KioskRemoteViewStatus.unconfirmed,
              'start_unconfirmed',
            );
          }
          _active = _ActiveRemote(
            record: record,
            receiptHandle: started.receiptHandle!,
            startContext: trusted,
          );
          return record.receipt = _receipt(
            record,
            KioskRemoteViewStatus.active,
            'start_observed',
          );
      }
    } catch (_) {
      return record.receipt = _receipt(
        record,
        KioskRemoteViewStatus.unconfirmed,
        'start_unconfirmed',
      );
    }
  }

  Future<KioskRemoteViewReceipt> reconcile(
    KioskRemoteViewContext trusted,
  ) async {
    final active = _active;
    final record = _record;
    if (active == null || record == null) {
      return record?.receipt ??
          const KioskRemoteViewReceipt(
            requestId: '00000000000000000000000000000000',
            mode: KioskRemoteViewMode.appSurface,
            status: KioskRemoteViewStatus.denied,
            reasonCode: 'no_active_view',
          );
    }
    if (_allowed(record.mode, trusted) &&
        trusted.binding == record.binding &&
        (record.mode != KioskRemoteViewMode.fullDeviceProjection ||
            trusted.projectionConsentRevision == record.consentRevision)) {
      return record.receipt!;
    }
    _active = null;
    _generation++;
    try {
      final stopped = await port
          .stop(active.receiptHandle, record.mode, active.startContext)
          .timeout(_portTimeout);
      return record.receipt = _receipt(
        record,
        stopped
            ? KioskRemoteViewStatus.retired
            : KioskRemoteViewStatus.unconfirmed,
        stopped ? 'stop_observed' : 'stop_unconfirmed',
      );
    } catch (_) {
      return record.receipt = _receipt(
        record,
        KioskRemoteViewStatus.unconfirmed,
        'stop_unconfirmed',
      );
    }
  }

  void invalidate() {
    if (_active != null) {
      throw StateError('active remote view must be reconciled');
    }
    _generation++;
    _record = null;
  }

  bool _allowed(KioskRemoteViewMode mode, KioskRemoteViewContext trusted) {
    if (!trusted.binding.valid ||
        !trusted.foreground ||
        !trusted.routeVisible ||
        !trusted.interactionActive ||
        trusted.sensitivity != KioskScreenSensitivity.ordinary) {
      return false;
    }
    try {
      if (!isCurrent(trusted.binding)) return false;
    } catch (_) {
      return false;
    }
    return mode != KioskRemoteViewMode.fullDeviceProjection ||
        (trusted.projectionConsentActive &&
            trusted.projectionConsentRevision != null &&
            _revision(trusted.projectionConsentRevision!));
  }

  Set<KioskRemoteViewMode> _capabilities() {
    try {
      return port.capabilities;
    } catch (_) {
      return const {};
    }
  }

  Future<void> _compensate(
    String receiptHandle,
    KioskRemoteViewMode mode,
    KioskRemoteViewContext trusted,
  ) async {
    try {
      await port.stop(receiptHandle, mode, trusted).timeout(_portTimeout);
    } catch (_) {
      // Starting may already have taken effect. Never report success or retry.
    }
  }

  static KioskRemoteViewReceipt _receipt(
    _RemoteRecord? record,
    KioskRemoteViewStatus status,
    String reason,
  ) => KioskRemoteViewReceipt(
    requestId: record?.requestId ?? '00000000000000000000000000000000',
    mode: record?.mode ?? KioskRemoteViewMode.appSurface,
    status: status,
    reasonCode: reason,
  );
}

final class _RemoteRecord {
  _RemoteRecord({
    required this.requestId,
    required this.mode,
    required this.binding,
    required this.consentRevision,
    required this.generation,
    required this.expiresAt,
    required this.unsupported,
  });

  final String requestId;
  final KioskRemoteViewMode mode;
  final KioskDeviceAuthority binding;
  final int? consentRevision;
  final int generation;
  final DateTime expiresAt;
  final bool unsupported;
  bool dispatching = false;
  KioskRemoteViewReceipt? receipt;
}

final class _ActiveRemote {
  const _ActiveRemote({
    required this.record,
    required this.receiptHandle,
    required this.startContext,
  });
  final _RemoteRecord record;
  final String receiptHandle;
  // Retirement uses the original receipt scope even after route/session drift.
  final KioskRemoteViewContext startContext;
}

bool _revision(int value) => value > 0 && value <= _maxRevision;
