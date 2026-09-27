enum VisualCpuSupport { supported, unsupported, unknown, notApplicable }

enum VisualArchitecture { amd64, arm64, other }

enum VisualDetectorState { unavailable, degraded, ready }

enum VisualSensorState { on, off, unknown }

enum VisualSensorStatus { ready, degraded, unavailable }

final class VisualEngineCapability {
  const VisualEngineCapability({
    required this.architecture,
    required this.avx,
    required this.avx2,
    required this.arm64,
    required this.reason,
    this.detectorState = VisualDetectorState.unavailable,
    this.trainingSupported = false,
    this.inferenceSupported = false,
  });
  final VisualArchitecture architecture;
  final VisualCpuSupport avx, avx2;
  final bool arm64;
  final String reason;
  final VisualDetectorState detectorState;
  final bool trainingSupported, inferenceSupported;
}

final class CameraVisualSensor {
  const CameraVisualSensor({
    required this.ruleId,
    required this.ruleRevision,
    required this.cameraId,
    required this.pipelineId,
    required this.pipelineRevision,
    required this.modelId,
    required this.modelRevision,
    required this.label,
    this.state = VisualSensorState.unknown,
    this.status = VisualSensorStatus.unavailable,
    this.reason = 'no_trusted_frame',
    this.observedAtMs,
    this.staleAtMs,
    this.evidenceDigest,
    this.confidenceBps = 0,
    this.count = 0,
    this.automationEligible = false,
  });
  final String ruleId, cameraId, pipelineId, modelId, label;
  final int ruleRevision, pipelineRevision, modelRevision;
  final VisualSensorState state;
  final VisualSensorStatus status;
  final String reason;
  final int? observedAtMs, staleAtMs;
  final String? evidenceDigest;
  final int confidenceBps, count;
  final bool automationEligible;
}

final class CameraVisualSensorSummary {
  const CameraVisualSensorSummary({
    required this.coreId,
    required this.homeId,
    required this.capability,
    required this.sensors,
  });
  final String coreId, homeId;
  final VisualEngineCapability capability;
  final List<CameraVisualSensor> sensors;
}

abstract interface class CameraVisualSensorGateway {
  Future<CameraVisualSensorSummary> load();
  void retire();
}
