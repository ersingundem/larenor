enum VisualCpuSupport { supported, unsupported, unknown, notApplicable }

enum VisualArchitecture { amd64, arm64, other }

final class VisualEngineCapability {
  const VisualEngineCapability({
    required this.architecture,
    required this.avx,
    required this.avx2,
    required this.arm64,
    required this.reason,
  });
  final VisualArchitecture architecture;
  final VisualCpuSupport avx, avx2;
  final bool arm64;
  final String reason;
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
  });
  final String ruleId, cameraId, pipelineId, modelId, label;
  final int ruleRevision, pipelineRevision, modelRevision;
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
