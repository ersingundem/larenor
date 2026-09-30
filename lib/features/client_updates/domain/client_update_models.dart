enum ClientUpdateFailure {
  unsupported,
  unavailable,
  authentication,
  permission,
  network,
  redirect,
  invalidMetadata,
  incompatible,
  verification,
  expired,
  cancelled,
  busy,
  installPermission,
}

class ClientUpdateException implements Exception {
  const ClientUpdateException(this.failure);
  final ClientUpdateFailure failure;
  @override
  String toString() => 'Client update unavailable';
}

Never _invalid() =>
    throw const ClientUpdateException(ClientUpdateFailure.invalidMetadata);
final _hex = RegExp(r'^[a-fA-F0-9]{64}$');
String _text(Map raw, String key, int max, {bool empty = false}) {
  final value = raw[key];
  if (value is! String ||
      value.length > max ||
      (!empty && value.trim().isEmpty) ||
      value.contains(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'))) {
    _invalid();
  }
  return value;
}

int _int(Map raw, String key, int min, int max) {
  final value = raw[key];
  if (value is! int || value < min || value > max) _invalid();
  return value;
}

bool _bool(Map raw, String key) {
  final value = raw[key];
  if (value is! bool) _invalid();
  return value;
}

class ClientRelease {
  ClientRelease._({
    required this.versionCode,
    required this.versionName,
    required this.certificateSha256,
    required this.apkSha256,
    required this.sizeBytes,
    required this.minSdk,
    required this.commit,
    required this.downloadPath,
    required this.publishedAt,
    required this.releaseNotes,
  });
  static const applicationId = 'com.ersingundem.larenor';
  static const maxBytes = 512 * 1024 * 1024;
  final int versionCode, sizeBytes, minSdk;
  final String versionName,
      certificateSha256,
      apkSha256,
      commit,
      downloadPath,
      releaseNotes;
  final DateTime publishedAt;
  factory ClientRelease.fromJson(Object? raw) {
    if (raw is! Map ||
        raw.length != 12 ||
        raw['schemaVersion'] != 1 ||
        raw['applicationId'] != applicationId) {
      _invalid();
    }
    final version = _int(raw, 'versionCode', 1, 2147483647);
    final cert = _text(raw, 'certificateSha256', 64);
    final hash = _text(raw, 'apkSha256', 64);
    final commit = _text(raw, 'commit', 40);
    final path = _text(raw, 'downloadPath', 100);
    final published = _text(raw, 'publishedAt', 64);
    final date = DateTime.tryParse(published);
    if (!_hex.hasMatch(cert) ||
        !_hex.hasMatch(hash) ||
        !RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(commit) ||
        path != '/api/v1/client/releases/$version/apk' ||
        date == null ||
        !RegExp(r'T.*(?:Z|[+-]\d{2}:\d{2})$').hasMatch(published)) {
      _invalid();
    }
    return ClientRelease._(
      versionCode: version,
      versionName: _text(raw, 'versionName', 80),
      certificateSha256: cert.toLowerCase(),
      apkSha256: hash.toLowerCase(),
      sizeBytes: _int(raw, 'sizeBytes', 1, maxBytes),
      minSdk: _int(raw, 'minSdk', 26, 26),
      commit: commit.toLowerCase(),
      downloadPath: path,
      publishedAt: date,
      releaseNotes: _text(raw, 'releaseNotes', 12000, empty: true),
    );
  }
  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'applicationId': applicationId,
    'versionCode': versionCode,
    'versionName': versionName,
    'certificateSha256': certificateSha256,
    'apkSha256': apkSha256,
    'sizeBytes': sizeBytes,
    'minSdk': minSdk,
    'commit': commit,
    'downloadPath': downloadPath,
    'publishedAt': publishedAt.toUtc().toIso8601String(),
    'releaseNotes': releaseNotes,
  };
  @override
  String toString() => 'Client release';
}

class InstalledClientSnapshot {
  const InstalledClientSnapshot.unsupported()
    : supported = false,
      versionCode = 0,
      versionName = '',
      certificateSha256 = const {},
      sdkInt = 0,
      canRequestPackageInstalls = false,
      deviceOwner = false,
      resumed = false,
      focused = false,
      interactionEpoch = 0,
      managedInstallReceipt = null;
  InstalledClientSnapshot._({
    required this.versionCode,
    required this.versionName,
    required Set<String> certificates,
    required this.sdkInt,
    required this.canRequestPackageInstalls,
    required this.deviceOwner,
    required this.resumed,
    required this.focused,
    required this.interactionEpoch,
    required this.managedInstallReceipt,
  }) : supported = true,
       certificateSha256 = Set.unmodifiable(certificates);
  final bool supported,
      canRequestPackageInstalls,
      deviceOwner,
      resumed,
      focused;
  final int versionCode, sdkInt, interactionEpoch;
  final String versionName;
  final Set<String> certificateSha256;
  final ManagedInstallReceipt? managedInstallReceipt;
  factory InstalledClientSnapshot.fromChannel(Object? raw) {
    if (raw is! Map ||
        raw.length != 12 ||
        raw['supported'] != true ||
        raw['applicationId'] != ClientRelease.applicationId) {
      _invalid();
    }
    final certs = raw['certificateSha256'];
    if (certs is! List ||
        certs.isEmpty ||
        certs.length > 8 ||
        certs.any((v) => v is! String || !_hex.hasMatch(v))) {
      _invalid();
    }
    final receipt = raw['managedInstallReceipt'] == null
        ? null
        : ManagedInstallReceipt.fromChannel(raw['managedInstallReceipt']);
    final snapshot = InstalledClientSnapshot._(
      versionCode: _int(raw, 'versionCode', 1, 2147483647),
      versionName: _text(raw, 'versionName', 80),
      certificates: certs.cast<String>().map((v) => v.toLowerCase()).toSet(),
      sdkInt: _int(raw, 'sdkInt', 26, 100),
      canRequestPackageInstalls: _bool(raw, 'canRequestPackageInstalls'),
      deviceOwner: _bool(raw, 'deviceOwner'),
      resumed: _bool(raw, 'resumed'),
      focused: _bool(raw, 'focused'),
      interactionEpoch: _int(raw, 'interactionEpoch', 0, 9007199254740991),
      managedInstallReceipt: receipt,
    );
    if (receipt?.confirmed == true &&
        (snapshot.versionCode != receipt!.expectedVersionCode ||
            !snapshot.certificateSha256.contains(
              receipt.observedCertificateSha256,
            ))) {
      _invalid();
    }
    return snapshot;
  }
  bool accepts(ClientRelease release) =>
      supported &&
      release.versionCode > versionCode &&
      release.minSdk <= sdkInt &&
      certificateSha256.length == 1 &&
      certificateSha256.contains(release.certificateSha256);
}

enum ManagedInstallReceiptStatus { confirmed, failed, cancelled, unknown }

class ManagedInstallReceipt {
  const ManagedInstallReceipt._({
    required this.requestId,
    required this.installerSessionId,
    required this.expectedVersionCode,
    required this.status,
    required this.observedVersionCode,
    required this.observedCertificateSha256,
    required this.observedAtEpochMs,
  });

  final String requestId;
  final int installerSessionId, expectedVersionCode, observedAtEpochMs;
  final ManagedInstallReceiptStatus status;
  final int? observedVersionCode;
  final String? observedCertificateSha256;

  bool get blocksDispatch => status == ManagedInstallReceiptStatus.unknown;
  bool get confirmed => status == ManagedInstallReceiptStatus.confirmed;

  factory ManagedInstallReceipt.fromChannel(Object? raw) {
    if (raw is! Map ||
        raw.length != 9 ||
        raw['schemaVersion'] != 1 ||
        raw['applicationId'] != ClientRelease.applicationId) {
      _invalid();
    }
    final requestId = _text(raw, 'requestId', 32);
    final status = ManagedInstallReceiptStatus.values
        .where((candidate) => candidate.name == raw['status'])
        .firstOrNull;
    final observedVersion = raw['observedVersionCode'];
    final observedCertificate = raw['observedCertificateSha256'];
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(requestId) ||
        status == null ||
        (observedVersion != null &&
            (observedVersion is! int ||
                observedVersion < 1 ||
                observedVersion > 2147483647)) ||
        (observedCertificate != null &&
            (observedCertificate is! String ||
                !_hex.hasMatch(observedCertificate))) ||
        ((observedVersion == null) != (observedCertificate == null))) {
      _invalid();
    }
    final expectedVersion = _int(raw, 'expectedVersionCode', 1, 2147483647);
    if (status == ManagedInstallReceiptStatus.confirmed &&
        (observedVersion != expectedVersion || observedCertificate == null)) {
      _invalid();
    }
    return ManagedInstallReceipt._(
      requestId: requestId,
      installerSessionId: _int(raw, 'installerSessionId', 0, 2147483647),
      expectedVersionCode: expectedVersion,
      status: status,
      observedVersionCode: observedVersion as int?,
      observedCertificateSha256: (observedCertificate as String?)
          ?.toLowerCase(),
      observedAtEpochMs: _int(raw, 'observedAtEpochMs', 0, 9007199254740991),
    );
  }
}

class StagedClientUpdate {
  const StagedClientUpdate({
    required this.id,
    required this.versionCode,
    required this.sizeBytes,
  });
  final String id;
  final int versionCode, sizeBytes;
  factory StagedClientUpdate.fromChannel(Object? raw) {
    if (raw is! Map || raw.length != 3) _invalid();
    final id = _text(raw, 'id', 36);
    if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(id)) _invalid();
    return StagedClientUpdate(
      id: id,
      versionCode: _int(raw, 'versionCode', 1, 2147483647),
      sizeBytes: _int(raw, 'sizeBytes', 1, ClientRelease.maxBytes),
    );
  }
}

enum ClientUpdateTransferPhase { downloading, verifying }

class ClientUpdateProgress {
  const ClientUpdateProgress({
    required this.sessionId,
    required this.downloadId,
    required this.receivedBytes,
    required this.totalBytes,
    required this.phase,
  });
  final String sessionId, downloadId;
  final int receivedBytes, totalBytes;
  final ClientUpdateTransferPhase phase;
  factory ClientUpdateProgress.fromChannel(Object? raw) {
    if (raw is! Map || raw.length != 5) _invalid();
    final total = _int(raw, 'totalBytes', 1, ClientRelease.maxBytes);
    final phase = ClientUpdateTransferPhase.values
        .where((v) => v.name == raw['phase'])
        .firstOrNull;
    if (phase == null) _invalid();
    return ClientUpdateProgress(
      sessionId: _text(raw, 'sessionId', 80),
      downloadId: _text(raw, 'downloadId', 36),
      receivedBytes: _int(raw, 'receivedBytes', 0, total),
      totalBytes: total,
      phase: phase,
    );
  }
}

enum ClientInstallOutcome { systemPromptOpened, managedInstallPending }
