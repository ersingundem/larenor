import 'dart:convert';
import 'dart:typed_data';

import '../data/remote_profiles.dart';

class VncFailure implements Exception {
  const VncFailure(this.code);
  final String code;
  @override
  String toString() => 'VncFailure($code)';
}

Never _invalid([String code = 'invalid_response']) => throw VncFailure(code);

Map<Object?, Object?> _object(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    _invalid();
  }
  return value;
}

bool _bool(Map<Object?, Object?> value, String key) {
  final result = value[key];
  if (result is! bool) _invalid();
  return result;
}

int _integer(
  Map<Object?, Object?> value,
  String key, {
  int min = 0,
  int max = 8192,
}) {
  final result = value[key];
  if (result is! int || result < min || result > max) _invalid();
  return result;
}

enum VncEngineAvailability { unavailable, available }

enum RfbProtocolVersion {
  v38('3.8');

  const RfbProtocolVersion(this.wireName);
  final String wireName;
}

enum RfbSecurityType {
  vencryptTlsVncAuth('vencrypt_tls_vnc_auth'),
  vncAuth('vnc_auth'),
  none('none');

  const RfbSecurityType(this.wireName);
  final String wireName;
}

T _enum<T extends Enum>(
  Object? value,
  Iterable<T> values,
  String Function(T) key,
) {
  return values.where((item) => key(item) == value).firstOrNull ?? _invalid();
}

Set<T> _enumSet<T extends Enum>(
  Object? value,
  Iterable<T> values,
  String Function(T) key,
) {
  if (value is! List || value.length > 8) _invalid();
  final result = value.map((item) => _enum(item, values, key)).toSet();
  if (result.length != value.length) _invalid();
  return Set.unmodifiable(result);
}

class VncCapabilities {
  const VncCapabilities._({
    required this.availability,
    required this.engineRevision,
    required this.supportedVersions,
    required this.supportedSecurity,
    required this.supportsTls,
    required this.supportsCertificatePinning,
    required this.supportsPasswordAuth,
    required this.supportsDynamicResolution,
    required this.supportsExternalDisplay,
    required this.maxWidth,
    required this.maxHeight,
    required this.maxDpi,
    required this.supportsTouchpad,
    required this.supportsKeyboard,
    required this.supportsClipboard,
    required this.supportsFiles,
  });

  final VncEngineAvailability availability;
  final String? engineRevision;
  final Set<RfbProtocolVersion> supportedVersions;
  final Set<RfbSecurityType> supportedSecurity;
  final bool supportsTls, supportsCertificatePinning, supportsPasswordAuth;
  final bool supportsDynamicResolution, supportsExternalDisplay;
  final int maxWidth, maxHeight, maxDpi;
  final bool supportsTouchpad, supportsKeyboard;
  final bool supportsClipboard, supportsFiles;

  bool get canConnect =>
      availability == VncEngineAvailability.available &&
      supportedVersions.contains(RfbProtocolVersion.v38) &&
      supportedSecurity.contains(RfbSecurityType.vencryptTlsVncAuth) &&
      supportsTls &&
      supportsCertificatePinning &&
      supportsPasswordAuth &&
      supportsTouchpad &&
      supportsKeyboard;

  factory VncCapabilities.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'availability',
      'engineRevision',
      'rfbVersions',
      'securityTypes',
      'security',
      'display',
      'input',
      'channels',
    });
    if (value['schemaVersion'] != 1) _invalid();
    final availability = switch (value['availability']) {
      'available' => VncEngineAvailability.available,
      'unavailable' => VncEngineAvailability.unavailable,
      _ => _invalid(),
    };
    final revision = value['engineRevision'];
    if (revision != null &&
        (revision is! String ||
            !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$')
                .hasMatch(revision))) {
      _invalid();
    }
    final security = _object(value['security'], {
          'tls',
          'certificatePinning',
          'passwordAuth',
        }),
        display = _object(value['display'], {
          'dynamicResolution',
          'externalDisplay',
          'maxWidth',
          'maxHeight',
          'maxDpi',
        }),
        input = _object(value['input'], {'touchpad', 'keyboard'}),
        channels = _object(value['channels'], {'clipboard', 'files'});
    final result = VncCapabilities._(
      availability: availability,
      engineRevision: revision as String?,
      supportedVersions: _enumSet(
        value['rfbVersions'],
        RfbProtocolVersion.values,
        (item) => item.wireName,
      ),
      supportedSecurity: _enumSet(
        value['securityTypes'],
        RfbSecurityType.values,
        (item) => item.wireName,
      ),
      supportsTls: _bool(security, 'tls'),
      supportsCertificatePinning: _bool(security, 'certificatePinning'),
      supportsPasswordAuth: _bool(security, 'passwordAuth'),
      supportsDynamicResolution: _bool(display, 'dynamicResolution'),
      supportsExternalDisplay: _bool(display, 'externalDisplay'),
      maxWidth: _integer(display, 'maxWidth'),
      maxHeight: _integer(display, 'maxHeight'),
      maxDpi: _integer(display, 'maxDpi', max: 640),
      supportsTouchpad: _bool(input, 'touchpad'),
      supportsKeyboard: _bool(input, 'keyboard'),
      supportsClipboard: _bool(channels, 'clipboard'),
      supportsFiles: _bool(channels, 'files'),
    );
    if (availability == VncEngineAvailability.unavailable &&
        (revision != null ||
            result.supportedVersions.isNotEmpty ||
            result.supportedSecurity.isNotEmpty ||
            result.supportsTls ||
            result.supportsCertificatePinning ||
            result.supportsPasswordAuth ||
            result.supportsDynamicResolution ||
            result.supportsExternalDisplay ||
            result.maxWidth != 0 ||
            result.maxHeight != 0 ||
            result.maxDpi != 0 ||
            result.supportsTouchpad ||
            result.supportsKeyboard ||
            result.supportsClipboard ||
            result.supportsFiles)) {
      _invalid();
    }
    if (availability == VncEngineAvailability.available &&
        (revision == null ||
            result.maxWidth < 640 ||
            result.maxHeight < 480 ||
            result.maxDpi < 72)) {
      _invalid();
    }
    return result;
  }
}

class VncCertificatePin {
  const VncCertificatePin({required this.algorithm, required this.fingerprint});
  final String algorithm, fingerprint;

  factory VncCertificatePin.fromJson(Object? raw) {
    final value = _object(raw, {'algorithm', 'fingerprint'});
    final result = VncCertificatePin(
      algorithm: value['algorithm'] is String
          ? value['algorithm'] as String
          : '',
      fingerprint: value['fingerprint'] is String
          ? value['fingerprint'] as String
          : '',
    );
    result.validate();
    return result;
  }

  void validate() {
    if (algorithm != 'spki-sha256' ||
        !RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$').hasMatch(fingerprint)) {
      _invalid('invalid_certificate');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is VncCertificatePin &&
      algorithm == other.algorithm &&
      fingerprint == other.fingerprint;
  @override
  int get hashCode => Object.hash(algorithm, fingerprint);
}

class VncTransportPolicy {
  const VncTransportPolicy({this.allowPlainVnc = false});
  static const lockedDown = VncTransportPolicy();
  final bool allowPlainVnc;
}

class RfbNegotiation {
  const RfbNegotiation._({
    required this.version,
    required this.securityType,
    required this.tls,
    required this.certificate,
    required this.requiresPassword,
  });
  final RfbProtocolVersion version;
  final RfbSecurityType securityType;
  final bool tls, requiresPassword;
  final VncCertificatePin? certificate;

  factory RfbNegotiation.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'rfbVersion',
      'securityType',
      'tls',
      'certificate',
      'requiresPassword',
    });
    if (value['schemaVersion'] != 1 ||
        value['tls'] is! bool ||
        value['requiresPassword'] is! bool) {
      _invalid();
    }
    final certificate = value['certificate'] == null
        ? null
        : VncCertificatePin.fromJson(value['certificate']);
    return RfbNegotiation._(
      version: _enum(
        value['rfbVersion'],
        RfbProtocolVersion.values,
        (item) => item.wireName,
      ),
      securityType: _enum(
        value['securityType'],
        RfbSecurityType.values,
        (item) => item.wireName,
      ),
      tls: value['tls'] as bool,
      certificate: certificate,
      requiresPassword: value['requiresPassword'] as bool,
    );
  }

  void validate(VncTransportPolicy policy) {
    if (version != RfbProtocolVersion.v38) _invalid('rfb_version_unsupported');
    if (securityType == RfbSecurityType.none) _invalid('no_auth_rejected');
    if (!tls || securityType == RfbSecurityType.vncAuth) {
      if (!policy.allowPlainVnc) _invalid('plain_vnc_rejected');
      _invalid('plain_vnc_unsupported');
    }
    if (securityType != RfbSecurityType.vencryptTlsVncAuth ||
        !requiresPassword ||
        certificate == null) {
      _invalid('security_unsupported');
    }
    certificate!.validate();
  }
}

class VncDisplaySpec {
  const VncDisplaySpec({
    required this.width,
    required this.height,
    required this.dpi,
    this.externalDisplay = false,
  });
  final int width, height, dpi;
  final bool externalDisplay;
  int get pixelCount => width * height;
  bool get valid =>
      width >= 640 &&
      height >= 480 &&
      width <= 8192 &&
      height <= 8192 &&
      dpi >= 72 &&
      dpi <= 640 &&
      pixelCount <= 33554432;
}

class VncChannelPolicy {
  const VncChannelPolicy({this.clipboard = false, this.files = false});
  static const lockedDown = VncChannelPolicy();
  final bool clipboard, files;
}

class VncSessionRequest {
  const VncSessionRequest({
    required this.profile,
    required this.display,
    required this.securityType,
    required this.certificateFingerprint,
    this.channels = VncChannelPolicy.lockedDown,
  });
  final RemoteProfile profile;
  final VncDisplaySpec display;
  final RfbSecurityType securityType;
  final String certificateFingerprint;
  final VncChannelPolicy channels;

  void validate(VncCapabilities capabilities) {
    if (profile.protocol != RemoteProtocol.vnc ||
        !display.valid ||
        !capabilities.canConnect ||
        securityType != RfbSecurityType.vencryptTlsVncAuth ||
        !capabilities.supportedSecurity.contains(securityType) ||
        display.width > capabilities.maxWidth ||
        display.height > capabilities.maxHeight ||
        display.dpi > capabilities.maxDpi ||
        (display.externalDisplay && !capabilities.supportsExternalDisplay) ||
        !RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$')
            .hasMatch(certificateFingerprint) ||
        (channels.clipboard && !capabilities.supportsClipboard) ||
        (channels.files && !capabilities.supportsFiles)) {
      _invalid('unsupported_request');
    }
  }

  @override
  String toString() =>
      'VncSessionRequest(${profile.id}, ${display.width}x${display.height}, '
      '${securityType.wireName})';
}

class VncEphemeralSecret {
  VncEphemeralSecret._(this._bytes);
  Uint8List? _bytes;

  factory VncEphemeralSecret.fromText(String value) {
    final bytes = utf8.encode(value);
    if (bytes.isEmpty || bytes.length > 4096 || value.contains('\u0000')) {
      _invalid('invalid_password');
    }
    return VncEphemeralSecret._(Uint8List.fromList(bytes));
  }

  VncSecretLease consume() {
    final bytes = _bytes;
    if (bytes == null) _invalid('secret_consumed');
    _bytes = null;
    return VncSecretLease._(bytes);
  }

  void dispose() {
    _bytes?.fillRange(0, _bytes!.length, 0);
    _bytes = null;
  }

  @override
  String toString() => 'VncEphemeralSecret(redacted)';
}

class VncSecretLease {
  VncSecretLease._(this.bytes);
  final Uint8List bytes;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    bytes.fillRange(0, bytes.length, 0);
  }

  @override
  String toString() => 'VncSecretLease(redacted)';
}

class VncPointerEvent {
  const VncPointerEvent({
    required this.x,
    required this.y,
    required this.buttons,
  });
  final double x, y;
  final int buttons;
  bool get valid =>
      x.isFinite &&
      y.isFinite &&
      x >= 0 &&
      x <= 1 &&
      y >= 0 &&
      y <= 1 &&
      buttons >= 0 &&
      buttons <= 31;
}

class VncKeyEvent {
  const VncKeyEvent({required this.physicalKey, required this.down});
  final int physicalKey;
  final bool down;
  bool get valid => physicalKey >= 1 && physicalKey <= 0xffff;
}
