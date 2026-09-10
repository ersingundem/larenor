import '../data/remote_profiles.dart';

class RdpFailure implements Exception {
  const RdpFailure(this.code);
  final String code;
  @override
  String toString() => 'RdpFailure($code)';
}

Never _invalid([String code = 'invalid_response']) => throw RdpFailure(code);

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

enum RdpEngineAvailability { unavailable, available }

class RdpCapabilities {
  const RdpCapabilities._({
    required this.availability,
    required this.engineRevision,
    required this.supportsTls,
    required this.supportsCertificatePinning,
    required this.supportsNla,
    required this.supportsDynamicResolution,
    required this.supportsExternalDisplay,
    required this.maxWidth,
    required this.maxHeight,
    required this.maxDpi,
    required this.supportsTouchpad,
    required this.supportsKeyboard,
    required this.supportsClipboard,
    required this.supportsAudio,
    required this.supportsFiles,
  });

  final RdpEngineAvailability availability;
  final String? engineRevision;
  final bool supportsTls, supportsCertificatePinning, supportsNla;
  final bool supportsDynamicResolution, supportsExternalDisplay;
  final int maxWidth, maxHeight, maxDpi;
  final bool supportsTouchpad, supportsKeyboard;
  final bool supportsClipboard, supportsAudio, supportsFiles;

  bool get canConnect =>
      availability == RdpEngineAvailability.available &&
      supportsTls &&
      supportsCertificatePinning &&
      supportsTouchpad &&
      supportsKeyboard;

  factory RdpCapabilities.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'availability',
      'engineRevision',
      'security',
      'display',
      'input',
      'channels',
    });
    if (value['schemaVersion'] != 1) _invalid();
    final availability = switch (value['availability']) {
      'available' => RdpEngineAvailability.available,
      'unavailable' => RdpEngineAvailability.unavailable,
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
          'nla',
        }),
        display = _object(value['display'], {
          'dynamicResolution',
          'externalDisplay',
          'maxWidth',
          'maxHeight',
          'maxDpi',
        }),
        input = _object(value['input'], {'touchpad', 'keyboard'}),
        channels = _object(value['channels'], {'clipboard', 'audio', 'files'});
    final result = RdpCapabilities._(
      availability: availability,
      engineRevision: revision as String?,
      supportsTls: _bool(security, 'tls'),
      supportsCertificatePinning: _bool(security, 'certificatePinning'),
      supportsNla: _bool(security, 'nla'),
      supportsDynamicResolution: _bool(display, 'dynamicResolution'),
      supportsExternalDisplay: _bool(display, 'externalDisplay'),
      maxWidth: _integer(display, 'maxWidth'),
      maxHeight: _integer(display, 'maxHeight'),
      maxDpi: _integer(display, 'maxDpi', max: 640),
      supportsTouchpad: _bool(input, 'touchpad'),
      supportsKeyboard: _bool(input, 'keyboard'),
      supportsClipboard: _bool(channels, 'clipboard'),
      supportsAudio: _bool(channels, 'audio'),
      supportsFiles: _bool(channels, 'files'),
    );
    if (availability == RdpEngineAvailability.unavailable &&
        (revision != null ||
            result.supportsTls ||
            result.supportsCertificatePinning ||
            result.supportsNla ||
            result.supportsDynamicResolution ||
            result.supportsExternalDisplay ||
            result.maxWidth != 0 ||
            result.maxHeight != 0 ||
            result.maxDpi != 0 ||
            result.supportsTouchpad ||
            result.supportsKeyboard ||
            result.supportsClipboard ||
            result.supportsAudio ||
            result.supportsFiles)) {
      _invalid();
    }
    if (availability == RdpEngineAvailability.available &&
        (revision == null ||
            result.maxWidth < 640 ||
            result.maxHeight < 480 ||
            result.maxDpi < 72)) {
      _invalid();
    }
    return result;
  }
}

class RdpCertificatePin {
  const RdpCertificatePin({required this.algorithm, required this.fingerprint});
  final String algorithm, fingerprint;
  factory RdpCertificatePin.fromJson(Object? raw) {
    final value = _object(raw, {'algorithm', 'fingerprint'});
    final result = RdpCertificatePin(
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
      other is RdpCertificatePin &&
      algorithm == other.algorithm &&
      fingerprint == other.fingerprint;
  @override
  int get hashCode => Object.hash(algorithm, fingerprint);
}

class RdpPeerSecurity {
  const RdpPeerSecurity({
    required this.tls,
    required this.requiresNla,
    required this.certificate,
  });
  final bool tls, requiresNla;
  final RdpCertificatePin certificate;
}

class RdpDisplaySpec {
  const RdpDisplaySpec({
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

class RdpChannelPolicy {
  const RdpChannelPolicy({
    this.clipboard = false,
    this.audio = false,
    this.files = false,
  });
  static const lockedDown = RdpChannelPolicy();
  final bool clipboard, audio, files;
}

class RdpSessionRequest {
  const RdpSessionRequest({
    required this.profile,
    required this.display,
    required this.certificateFingerprint,
    this.channels = RdpChannelPolicy.lockedDown,
  });
  final RemoteProfile profile;
  final RdpDisplaySpec display;
  final String certificateFingerprint;
  final RdpChannelPolicy channels;

  void validate(RdpCapabilities capabilities) {
    if (profile.protocol != RemoteProtocol.rdp ||
        profile.username.isEmpty ||
        !display.valid ||
        !capabilities.canConnect ||
        display.width > capabilities.maxWidth ||
        display.height > capabilities.maxHeight ||
        display.dpi > capabilities.maxDpi ||
        (display.externalDisplay && !capabilities.supportsExternalDisplay) ||
        !RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$')
            .hasMatch(certificateFingerprint) ||
        (channels.clipboard && !capabilities.supportsClipboard) ||
        (channels.audio && !capabilities.supportsAudio) ||
        (channels.files && !capabilities.supportsFiles)) {
      _invalid('unsupported_request');
    }
  }
}

class RdpPointerEvent {
  const RdpPointerEvent({
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

class RdpKeyEvent {
  const RdpKeyEvent({required this.physicalKey, required this.down});
  final int physicalKey;
  final bool down;
  bool get valid => physicalKey >= 1 && physicalKey <= 0xffff;
}
