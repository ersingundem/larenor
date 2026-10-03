import 'dart:typed_data';

import '../data/remote_profiles.dart';
import 'rdp_models.dart';
import 'rdp_security_store.dart';

final _hex32 = RegExp(r'^[0-9a-f]{32}$');
final _pin = RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$');

enum RdpGatewayCertificateKind { gateway, target }

final class RdpGatewayEndpoint {
  RdpGatewayEndpoint({
    required this.host,
    required this.port,
    required this.username,
    this.domain = '',
  }) {
    try {
      if (normalizeRemoteHost(host) != host) _invalid();
    } catch (_) {
      _invalid();
    }
    if (port < 1 ||
        port > 65535 ||
        !_text(username, 128) ||
        !_text(domain, 128, empty: true)) {
      _invalid();
    }
  }

  final String host, username, domain;
  final int port;

  Map<String, Object> toWire({required bool includeDomain}) => {
    'host': host,
    'port': port,
    'username': username,
    if (includeDomain) 'domain': domain,
  };

  @override
  bool operator ==(Object other) =>
      other is RdpGatewayEndpoint &&
      host == other.host &&
      port == other.port &&
      username == other.username &&
      domain == other.domain;

  @override
  int get hashCode => Object.hash(host, port, username, domain);
}

final class RdpPinnedGatewayEndpoint {
  RdpPinnedGatewayEndpoint({
    required this.endpoint,
    required this.fingerprint,
  }) {
    RdpCertificatePin(
      algorithm: 'spki-sha256',
      fingerprint: fingerprint,
    ).validate();
  }

  final RdpGatewayEndpoint endpoint;
  final String fingerprint;

  Map<String, Object?> toWire() => {
    ...endpoint.toWire(includeDomain: true),
    'certificateFingerprint': fingerprint,
  };
}

final class RdpGatewayCertificateObservation {
  const RdpGatewayCertificateObservation({
    required this.requestId,
    required this.kind,
    required this.certificate,
  });

  final String requestId;
  final RdpGatewayCertificateKind kind;
  final RdpCertificatePin certificate;

  factory RdpGatewayCertificateObservation.fromWire(
    Object? raw, {
    required String requestId,
    required RdpGatewayCertificateKind kind,
  }) {
    final value = _closed(raw, {
      'schemaVersion',
      'requestId',
      'kind',
      'certificateFingerprint',
    });
    if (value['schemaVersion'] != 6 ||
        value['requestId'] != requestId ||
        value['kind'] != kind.name ||
        value['certificateFingerprint'] is! String) {
      _invalidResponse();
    }
    final certificate = RdpCertificatePin(
      algorithm: 'spki-sha256',
      fingerprint: value['certificateFingerprint']! as String,
    )..validate();
    return RdpGatewayCertificateObservation(
      requestId: requestId,
      kind: kind,
      certificate: certificate,
    );
  }
}

final class RdpCoreGatewaySecurity {
  RdpCoreGatewaySecurity({
    required this.endpoint,
    required this.certificateFingerprint,
  }) {
    RdpCertificatePin(
      algorithm: 'spki-sha256',
      fingerprint: certificateFingerprint,
    ).validate();
  }

  final RdpGatewayEndpoint endpoint;
  final String certificateFingerprint;

  Map<String, Object> toJson() => {
    ...endpoint.toWire(includeDomain: true),
    'certificateFingerprint': certificateFingerprint,
  };

  factory RdpCoreGatewaySecurity.fromJson(Object? raw) {
    final value = _closed(raw, {
      'host',
      'port',
      'username',
      'domain',
      'certificateFingerprint',
    });
    if (value['host'] is! String ||
        value['port'] is! int ||
        value['username'] is! String ||
        value['domain'] is! String ||
        value['certificateFingerprint'] is! String) {
      _invalidResponse();
    }
    return RdpCoreGatewaySecurity(
      endpoint: RdpGatewayEndpoint(
        host: value['host']! as String,
        port: value['port']! as int,
        username: value['username']! as String,
        domain: value['domain']! as String,
      ),
      certificateFingerprint: value['certificateFingerprint']! as String,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RdpCoreGatewaySecurity &&
      endpoint == other.endpoint &&
      certificateFingerprint == other.certificateFingerprint;

  @override
  int get hashCode => Object.hash(endpoint, certificateFingerprint);
}

/// Strict public Core projection. It contains no password, secret reference, or defaults.
final class RdpCoreSecurityProjection {
  RdpCoreSecurityProjection({
    required this.domain,
    required this.certificateFingerprint,
    this.gateway,
  }) {
    if (!_text(domain, 128, empty: true) ||
        !_pin.hasMatch(certificateFingerprint)) {
      _invalidResponse();
    }
  }

  final String domain, certificateFingerprint;
  final RdpCoreGatewaySecurity? gateway;

  Map<String, Object?> toJson() => {
    'domain': domain,
    'certificateFingerprint': certificateFingerprint,
    'gateway': gateway?.toJson(),
  };

  factory RdpCoreSecurityProjection.fromJson(Object? raw) {
    final value = _closed(raw, {'domain', 'certificateFingerprint', 'gateway'});
    if (value['domain'] is! String ||
        value['certificateFingerprint'] is! String ||
        value['gateway'] != null && value['gateway'] is! Map) {
      _invalidResponse();
    }
    return RdpCoreSecurityProjection(
      domain: value['domain']! as String,
      certificateFingerprint: value['certificateFingerprint']! as String,
      gateway: value['gateway'] == null
          ? null
          : RdpCoreGatewaySecurity.fromJson(value['gateway']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RdpCoreSecurityProjection &&
      domain == other.domain &&
      certificateFingerprint == other.certificateFingerprint &&
      gateway == other.gateway;

  @override
  int get hashCode => Object.hash(domain, certificateFingerprint, gateway);
}

final class RdpDeviceSecretReference {
  RdpDeviceSecretReference(this.value) {
    if (!_hex32.hasMatch(value)) _invalid();
  }
  final String value;
  @override
  String toString() => 'RdpDeviceSecretReference(<redacted>)';
  @override
  bool operator ==(Object other) =>
      other is RdpDeviceSecretReference && value == other.value;
  @override
  int get hashCode => value.hashCode;
}

enum RdpTransferState { prepared, active, sealed, saved, unknown }

final class RdpSchema6SessionOwner {
  RdpSchema6SessionOwner({required this.requestId, required this.revision}) {
    if (!RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(requestId) ||
        revision < 1 ||
        revision > 9007199254740991) {
      _invalid();
    }
  }

  final String requestId;
  final int revision;

  @override
  bool operator ==(Object other) =>
      other is RdpSchema6SessionOwner &&
      requestId == other.requestId &&
      revision == other.revision;

  @override
  int get hashCode => Object.hash(requestId, revision);
}

final class RdpTransferReceipt {
  RdpTransferReceipt({
    required this.requestId,
    required this.authorityId,
    required this.grant,
    required this.transferId,
    required this.state,
  }) {
    grant.validate();
    if (!_hex32.hasMatch(transferId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(authorityId)) {
      _invalidResponse();
    }
  }

  final String requestId, authorityId, transferId;
  final RdpFileTransferGrant grant;
  final RdpTransferState state;

  factory RdpTransferReceipt.fromWire(
    Object? raw, {
    required String requestId,
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    Set<RdpTransferState>? allowedStates,
    String? expectedTransferId,
  }) {
    final value = _closed(raw, {
      'schemaVersion',
      'requestId',
      'authorityId',
      'grantId',
      'grantRevision',
      'transferId',
      'state',
    });
    final state = value['state'] is String
        ? RdpTransferState.values
              .where((candidate) => candidate.name == value['state'])
              .firstOrNull
        : null;
    if (value['schemaVersion'] != 6 ||
        value['requestId'] != requestId ||
        value['authorityId'] != authority.authorityId ||
        value['grantId'] != grant.id ||
        value['grantRevision'] != grant.revision ||
        value['transferId'] is! String ||
        expectedTransferId != null &&
            value['transferId'] != expectedTransferId ||
        state == null ||
        allowedStates != null && !allowedStates.contains(state)) {
      _invalidResponse();
    }
    return RdpTransferReceipt(
      requestId: requestId,
      authorityId: authority.authorityId,
      grant: grant,
      transferId: value['transferId']! as String,
      state: state,
    );
  }

  @override
  String toString() => 'RdpTransferReceipt(${state.name}, redacted)';
}

final class RdpSchema6SessionBinding {
  RdpSchema6SessionBinding({required this.owner, this.transfer}) {
    if (transfer != null && transfer!.state != RdpTransferState.prepared) {
      _invalid();
    }
  }
  final RdpSchema6SessionOwner owner;
  final RdpTransferReceipt? transfer;
  bool get hasFileTransfer => transfer != null;

  Map<String, Object?> toWire() => {
    'schemaVersion': 6,
    'requestId': owner.requestId,
    'sessionRevision': owner.revision,
    'fileTransfer': transfer == null
        ? null
        : {'transferId': transfer!.transferId},
  };
}

final class RdpOwnedSecretBuffer {
  RdpOwnedSecretBuffer(Uint8List bytes) : bytes = Uint8List.fromList(bytes);
  final Uint8List bytes;
  bool _consumed = false;
  Uint8List take() {
    if (_consumed) throw const RdpFailure('retired');
    _consumed = true;
    return bytes;
  }

  void wipe() => bytes.fillRange(0, bytes.length, 0);
}

Map<Object?, Object?> _closed(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.keys.toSet().difference(keys).isNotEmpty ||
      keys.difference(raw.keys.whereType<String>().toSet()).isNotEmpty) {
    _invalidResponse();
  }
  return raw;
}

bool _text(String value, int max, {bool empty = false}) =>
    (empty || value.isNotEmpty) &&
    value == value.trim() &&
    value.runes.length <= max &&
    !value.runes.any(
      (rune) =>
          rune < 32 ||
          rune == 127 ||
          rune >= 0xd800 && rune <= 0xdfff ||
          rune >= 0x202a && rune <= 0x202e ||
          rune >= 0x2066 && rune <= 0x2069,
    );

Never _invalid() => throw const RdpFailure('invalid_request');
Never _invalidResponse() => throw const RdpFailure('invalid_response');
