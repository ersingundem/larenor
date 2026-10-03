import '../data/remote_profiles.dart';

class RdpFailure implements Exception {
  const RdpFailure(this.code);
  final String code;
  @override
  String toString() => 'RdpFailure($code)';
}

Never _invalid([String code = 'invalid_response']) => throw RdpFailure(code);

bool validRdpImeText(String value) => _validUtf8Text(value, 4096);

bool validRdpClipboardText(String value) => _validUtf8Text(value, 64 * 1024);

bool _validUtf8Text(String value, int maximumBytes) {
  if (value.isEmpty) return false;
  var bytes = 0;
  for (var index = 0; index < value.length; index++) {
    final unit = value.codeUnitAt(index);
    if (unit == 0) return false;
    if (unit <= 0x7f) {
      bytes++;
    } else if (unit <= 0x7ff) {
      bytes += 2;
    } else if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= value.length) return false;
      final low = value.codeUnitAt(index);
      if (low < 0xdc00 || low > 0xdfff) return false;
      bytes += 4;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    } else {
      bytes += 3;
    }
    if (bytes > maximumBytes) return false;
  }
  return true;
}

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

enum RdpAudioState { pending, deviceOpen, playing, closed, failed }

enum RdpMicrophoneState { pending, opened, captured, sent, closed, failed }

/// Finite observations from this session's microphone channel. A captured
/// buffer is local device activity; only [acceptedCount] records successful
/// submission to the RDP channel. Neither counter proves a remote effect.
class RdpMicrophoneObservation {
  const RdpMicrophoneObservation._({
    required this.state,
    required this.deviceOpen,
    required this.capturedCount,
    required this.acceptedCount,
  });

  final RdpMicrophoneState state;
  final bool deviceOpen;
  final int capturedCount, acceptedCount;
  bool get hasSubmittedAudio => acceptedCount > 0;

  factory RdpMicrophoneObservation.fromJson(
    Object? raw, {
    required String requestId,
    int schemaVersion = 4,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'requestId',
      'state',
      'deviceOpen',
      'capturedCount',
      'acceptedCount',
    });
    if (value['schemaVersion'] != schemaVersion ||
        value['requestId'] != requestId) {
      _invalid();
    }
    final state = RdpMicrophoneState.values
        .where((candidate) => candidate.name == value['state'])
        .firstOrNull;
    if (state == null) _invalid();
    final deviceOpen = _bool(value, 'deviceOpen');
    final captured = _integer(value, 'capturedCount', max: 9007199254740991);
    final accepted = _integer(value, 'acceptedCount', max: captured);
    if (deviceOpen !=
            (state == RdpMicrophoneState.opened ||
                state == RdpMicrophoneState.captured ||
                state == RdpMicrophoneState.sent) ||
        state == RdpMicrophoneState.pending &&
            (captured != 0 || accepted != 0) ||
        state == RdpMicrophoneState.opened &&
            (captured != 0 || accepted != 0) ||
        state == RdpMicrophoneState.captured && captured == 0 ||
        state == RdpMicrophoneState.sent && accepted == 0) {
      _invalid();
    }
    return RdpMicrophoneObservation._(
      state: state,
      deviceOpen: deviceOpen,
      capturedCount: captured,
      acceptedCount: accepted,
    );
  }

  bool follows(RdpMicrophoneObservation previous) =>
      capturedCount >= previous.capturedCount &&
      acceptedCount >= previous.acceptedCount &&
      (previous.state != RdpMicrophoneState.closed ||
          state == RdpMicrophoneState.closed) &&
      (previous.state != RdpMicrophoneState.failed ||
          state == RdpMicrophoneState.failed) &&
      (state != RdpMicrophoneState.pending ||
          previous.state == RdpMicrophoneState.pending) &&
      (state != RdpMicrophoneState.opened ||
          previous.state == RdpMicrophoneState.pending ||
          previous.state == RdpMicrophoneState.opened);

  @override
  bool operator ==(Object other) =>
      other is RdpMicrophoneObservation &&
      state == other.state &&
      deviceOpen == other.deviceOpen &&
      capturedCount == other.capturedCount &&
      acceptedCount == other.acceptedCount;
  @override
  int get hashCode =>
      Object.hash(state, deviceOpen, capturedCount, acceptedCount);
}

/// Finite counters from this session's native audio device. A server wave
/// confirmation or an accepted buffer alone does not prove playback.
class RdpAudioObservation {
  const RdpAudioObservation._({
    required this.state,
    required this.deviceOpen,
    required this.acceptedCount,
    required this.completedCount,
  });
  final RdpAudioState state;
  final bool deviceOpen;
  final int acceptedCount, completedCount;
  bool get hasCompletedPlayback => deviceOpen && completedCount > 0;

  factory RdpAudioObservation.fromJson(
    Object? raw, {
    required String requestId,
    int schemaVersion = 4,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'requestId',
      'state',
      'deviceOpen',
      'acceptedCount',
      'completedCount',
    });
    if (value['schemaVersion'] != schemaVersion ||
        value['requestId'] != requestId) {
      _invalid();
    }
    final state = RdpAudioState.values
        .where((v) => v.name == value['state'])
        .firstOrNull;
    if (state == null) _invalid();
    final deviceOpen = _bool(value, 'deviceOpen');
    final accepted = _integer(value, 'acceptedCount', max: 9007199254740991);
    final completed = _integer(value, 'completedCount', max: accepted);
    if (deviceOpen !=
            (state == RdpAudioState.deviceOpen ||
                state == RdpAudioState.playing) ||
        state == RdpAudioState.pending && (accepted != 0 || completed != 0) ||
        state == RdpAudioState.playing && accepted == 0) {
      _invalid();
    }
    return RdpAudioObservation._(
      state: state,
      deviceOpen: deviceOpen,
      acceptedCount: accepted,
      completedCount: completed,
    );
  }

  bool follows(RdpAudioObservation previous) =>
      acceptedCount >= previous.acceptedCount &&
      completedCount >= previous.completedCount &&
      (previous.state != RdpAudioState.failed || state == previous.state) &&
      (state != RdpAudioState.pending ||
          previous.state == RdpAudioState.pending);

  @override
  bool operator ==(Object other) =>
      other is RdpAudioObservation &&
      state == other.state &&
      deviceOpen == other.deviceOpen &&
      acceptedCount == other.acceptedCount &&
      completedCount == other.completedCount;
  @override
  int get hashCode =>
      Object.hash(state, deviceOpen, acceptedCount, completedCount);
}

class RdpCapabilities {
  const RdpCapabilities._({
    required this.availability,
    required this.engineRevision,
    required this.supportsTls,
    required this.supportsCertificatePinning,
    required this.supportsNla,
    required this.supportsRdGateway,
    required this.supportsDynamicResolution,
    required this.supportsExternalDisplay,
    required this.maxWidth,
    required this.maxHeight,
    required this.desktopScaleFactorMin,
    required this.desktopScaleFactorMax,
    required this.deviceScaleFactors,
    required this.supportsAbsolutePointer,
    required this.supportsRelativePointerNegotiation,
    required this.supportsVerticalWheel,
    required this.supportsKeyboard,
    required this.supportsIme,
    required this.supportsClipboard,
    required this.supportedClipboardModes,
    required this.supportsAudio,
    required this.supportsMicrophone,
    required this.supportsFiles,
  });

  final RdpEngineAvailability availability;
  final String? engineRevision;
  final bool supportsTls,
      supportsCertificatePinning,
      supportsNla,
      supportsRdGateway;
  final bool supportsDynamicResolution, supportsExternalDisplay;
  final int maxWidth, maxHeight, desktopScaleFactorMin, desktopScaleFactorMax;
  final Set<int> deviceScaleFactors;
  final bool supportsAbsolutePointer,
      supportsRelativePointerNegotiation,
      supportsVerticalWheel,
      supportsKeyboard,
      supportsIme;
  final bool supportsClipboard,
      supportsAudio,
      supportsMicrophone,
      supportsFiles;
  final Set<RdpClipboardMode> supportedClipboardModes;

  bool get canConnect =>
      availability == RdpEngineAvailability.available &&
      supportsTls &&
      supportsCertificatePinning &&
      supportsAbsolutePointer &&
      supportsKeyboard;

  bool acceptsDisplay(RdpDisplaySpec display) =>
      display.valid &&
      display.width <= maxWidth &&
      display.height <= maxHeight &&
      display.desktopScaleFactor >= desktopScaleFactorMin &&
      display.desktopScaleFactor <= desktopScaleFactorMax &&
      deviceScaleFactors.contains(display.deviceScaleFactor) &&
      (!display.externalDisplay || supportsExternalDisplay);

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
    if (value['schemaVersion'] != 4) _invalid();
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
      'rdGateway',
    });
    final display = _object(value['display'], {
      'dynamicResolution',
      'externalDisplay',
      'maxWidth',
      'maxHeight',
      'desktopScaleFactorMin',
      'desktopScaleFactorMax',
      'deviceScaleFactors',
    });
    final input = _object(value['input'], {
      'absolutePointer',
      'relativePointerNegotiation',
      'verticalWheel',
      'keyboard',
      'ime',
    });
    final channels = _object(value['channels'], {
      'clipboard',
      'clipboardModes',
      'audio',
      'microphone',
      'files',
    });
    final clipboard = _bool(channels, 'clipboard');
    final rawModes = channels['clipboardModes'];
    if (rawModes is! List || rawModes.length > RdpClipboardMode.values.length) {
      _invalid();
    }
    final modes = <RdpClipboardMode>{};
    var previous = -1;
    for (final rawMode in rawModes) {
      final mode = RdpClipboardMode.values
          .where((value) => value.name == rawMode)
          .firstOrNull;
      if (mode == null || mode.index <= previous) _invalid();
      previous = mode.index;
      modes.add(mode);
    }
    if (clipboard != modes.any((mode) => mode != RdpClipboardMode.disabled)) {
      _invalid();
    }
    final rawScales = display['deviceScaleFactors'];
    if (rawScales is! List || rawScales.length > 3) _invalid();
    final scales = <int>{};
    var previousScale = 0;
    for (final scale in rawScales) {
      if (scale is! int ||
          !const {100, 140, 180}.contains(scale) ||
          scale <= previousScale) {
        _invalid();
      }
      previousScale = scale;
      scales.add(scale);
    }
    final result = RdpCapabilities._(
      availability: availability,
      engineRevision: revision as String?,
      supportsTls: _bool(security, 'tls'),
      supportsCertificatePinning: _bool(security, 'certificatePinning'),
      supportsNla: _bool(security, 'nla'),
      supportsRdGateway: _bool(security, 'rdGateway'),
      supportsDynamicResolution: _bool(display, 'dynamicResolution'),
      supportsExternalDisplay: _bool(display, 'externalDisplay'),
      maxWidth: _integer(display, 'maxWidth'),
      maxHeight: _integer(display, 'maxHeight'),
      desktopScaleFactorMin: _integer(
        display,
        'desktopScaleFactorMin',
        max: 500,
      ),
      desktopScaleFactorMax: _integer(
        display,
        'desktopScaleFactorMax',
        max: 500,
      ),
      deviceScaleFactors: Set.unmodifiable(scales),
      supportsAbsolutePointer: _bool(input, 'absolutePointer'),
      supportsRelativePointerNegotiation: _bool(
        input,
        'relativePointerNegotiation',
      ),
      supportsVerticalWheel: _bool(input, 'verticalWheel'),
      supportsKeyboard: _bool(input, 'keyboard'),
      supportsIme: _bool(input, 'ime'),
      supportsClipboard: clipboard,
      supportedClipboardModes: Set.unmodifiable(modes),
      supportsAudio: _bool(channels, 'audio'),
      supportsMicrophone: _bool(channels, 'microphone'),
      supportsFiles: _bool(channels, 'files'),
    );
    if (availability == RdpEngineAvailability.unavailable &&
        (revision != null ||
            result.supportsTls ||
            result.supportsCertificatePinning ||
            result.supportsNla ||
            result.supportsRdGateway ||
            result.supportsDynamicResolution ||
            result.supportsExternalDisplay ||
            result.maxWidth != 0 ||
            result.maxHeight != 0 ||
            result.desktopScaleFactorMin != 0 ||
            result.desktopScaleFactorMax != 0 ||
            scales.isNotEmpty ||
            result.supportsAbsolutePointer ||
            result.supportsRelativePointerNegotiation ||
            result.supportsVerticalWheel ||
            result.supportsKeyboard ||
            result.supportsIme ||
            result.supportsClipboard ||
            modes.isNotEmpty ||
            result.supportsAudio ||
            result.supportsMicrophone ||
            result.supportsFiles)) {
      _invalid();
    }
    if (availability == RdpEngineAvailability.available &&
        (revision == null ||
            result.maxWidth < 640 ||
            result.maxHeight < 480 ||
            result.desktopScaleFactorMin != 100 ||
            result.desktopScaleFactorMax != 500 ||
            scales.length != 3 ||
            !modes.contains(RdpClipboardMode.disabled))) {
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

/// Certificate-only discovery performed before credentials are supplied.
///
/// [tlsCertificateObserved] means the native probe received a certificate on
/// its locally enforced TLS path. [clientRequiresNla] is the fixed Client
/// connection policy; neither field claims that the probe authenticated the
/// peer or discovered a server-selected authentication mode.
class RdpCertificateProbe {
  const RdpCertificateProbe({
    required this.tlsCertificateObserved,
    required this.clientRequiresNla,
    required this.certificate,
  });
  final bool tlsCertificateObserved, clientRequiresNla;
  final RdpCertificatePin certificate;
}

class RdpDisplaySpec {
  const RdpDisplaySpec({
    required this.width,
    required this.height,
    this.desktopScaleFactor = 100,
    this.deviceScaleFactor = 100,
    this.externalDisplay = false,
  });
  final int width, height, desktopScaleFactor, deviceScaleFactor;
  final bool externalDisplay;
  int get pixelCount => width * height;
  bool get valid =>
      width >= 640 &&
      width <= 8192 &&
      width.isEven &&
      height >= 480 &&
      height <= 8192 &&
      pixelCount <= 16777216 &&
      desktopScaleFactor >= 100 &&
      desktopScaleFactor <= 500 &&
      const {100, 140, 180}.contains(deviceScaleFactor);

  /// Requests protocol scale percentages. It does not attest remote OS scaling.
  factory RdpDisplaySpec.fromViewport({
    required int widthPixels,
    required int heightPixels,
    required double devicePixelRatio,
    bool externalDisplay = false,
  }) {
    if (widthPixels <= 0 ||
        heightPixels <= 0 ||
        !devicePixelRatio.isFinite ||
        devicePixelRatio <= 0) {
      _invalid('unsupported_request');
    }
    final desktop = (devicePixelRatio * 100).round().clamp(100, 500);
    final device = [
      100,
      140,
      180,
    ].reduce((a, b) => (desktop - a).abs() <= (desktop - b).abs() ? a : b);
    final width = widthPixels.clamp(640, 8192);
    return RdpDisplaySpec(
      width: width - width % 2,
      height: heightPixels.clamp(480, (16777216 ~/ width).clamp(480, 8192)),
      desktopScaleFactor: desktop,
      deviceScaleFactor: device,
      externalDisplay: externalDisplay,
    );
  }

  Map<String, Object?> toChannel() => {
    'width': width,
    'height': height,
    'desktopScaleFactor': desktopScaleFactor,
    'deviceScaleFactor': deviceScaleFactor,
    'externalDisplay': externalDisplay,
    'dynamicResize': true,
  };
  @override
  bool operator ==(Object other) =>
      other is RdpDisplaySpec &&
      width == other.width &&
      height == other.height &&
      desktopScaleFactor == other.desktopScaleFactor &&
      deviceScaleFactor == other.deviceScaleFactor &&
      externalDisplay == other.externalDisplay;
  @override
  int get hashCode => Object.hash(
    width,
    height,
    desktopScaleFactor,
    deviceScaleFactor,
    externalDisplay,
  );
}

enum RdpDisplayMode { fitWindow, fillWindow, native }

enum RdpKeyboardLayout { automatic, turkishQ, us }

enum RdpClipboardMode { disabled, clientToRemote, bidirectional }

class RdpFileTransferGrant {
  const RdpFileTransferGrant({required this.id, required this.revision});

  static final _identity = RegExp(r'^[0-9a-f]{32}$');
  static const maximumRevision = 9007199254740991;

  final String id;
  final int revision;

  void validate() {
    if (!_identity.hasMatch(id) || revision < 1 || revision > maximumRevision) {
      _invalid('invalid_settings');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is RdpFileTransferGrant &&
      id == other.id &&
      revision == other.revision;

  @override
  int get hashCode => Object.hash(id, revision);

  @override
  String toString() => 'RdpFileTransferGrant(redacted, revision: $revision)';
}

enum RdpFileTransferGrantState { prepared, active, retired, unknown }

class RdpFileTransferGrantObservation {
  const RdpFileTransferGrantObservation({
    required this.authorityId,
    required this.grant,
    required this.state,
  });

  final String authorityId;
  final RdpFileTransferGrant grant;
  final RdpFileTransferGrantState state;

  bool get usable => state == RdpFileTransferGrantState.active;

  @override
  bool operator ==(Object other) =>
      other is RdpFileTransferGrantObservation &&
      authorityId == other.authorityId &&
      grant == other.grant &&
      state == other.state;

  @override
  int get hashCode => Object.hash(authorityId, grant, state);

  @override
  String toString() =>
      'RdpFileTransferGrantObservation(${state.name}, redacted)';
}

class RdpProfileSettings {
  const RdpProfileSettings({
    this.domain = '',
    this.gatewayHost,
    this.gatewayPort = 443,
    this.gatewayUsername = '',
    this.gatewayDomain = '',
    this.displayMode = RdpDisplayMode.fitWindow,
    this.keyboardLayout = RdpKeyboardLayout.automatic,
    this.clipboardMode = RdpClipboardMode.disabled,
    this.microphone = false,
    this.fileTransferGrant,
  });

  final String domain;
  final String? gatewayHost;
  final int gatewayPort;
  final String gatewayUsername;
  final String gatewayDomain;
  final RdpDisplayMode displayMode;
  final RdpKeyboardLayout keyboardLayout;
  final RdpClipboardMode clipboardMode;
  final bool microphone;
  final RdpFileTransferGrant? fileTransferGrant;

  static const _unchanged = Object();

  RdpProfileSettings copyWith({
    RdpDisplayMode? displayMode,
    RdpKeyboardLayout? keyboardLayout,
    RdpClipboardMode? clipboardMode,
    bool? microphone,
    Object? fileTransferGrant = _unchanged,
  }) => RdpProfileSettings(
    domain: domain,
    gatewayHost: gatewayHost,
    gatewayPort: gatewayPort,
    gatewayUsername: gatewayUsername,
    gatewayDomain: gatewayDomain,
    displayMode: displayMode ?? this.displayMode,
    keyboardLayout: keyboardLayout ?? this.keyboardLayout,
    clipboardMode: clipboardMode ?? this.clipboardMode,
    microphone: microphone ?? this.microphone,
    fileTransferGrant: identical(fileTransferGrant, _unchanged)
        ? this.fileTransferGrant
        : fileTransferGrant as RdpFileTransferGrant?,
  );

  static bool _safeText(String value, int max) =>
      value == value.trim() &&
      value.runes.length <= max &&
      !value.runes.any(
        (value) =>
            value < 32 ||
            value == 127 ||
            (value >= 0xd800 && value <= 0xdfff) ||
            (value >= 0x202a && value <= 0x202e) ||
            (value >= 0x2066 && value <= 0x2069),
      );

  void validate() {
    if (!_safeText(domain, 128) ||
        !_safeText(gatewayUsername, 128) ||
        !_safeText(gatewayDomain, 128) ||
        gatewayPort < 1 ||
        gatewayPort > 65535) {
      _invalid('invalid_settings');
    }
    if (gatewayHost != null) {
      try {
        if (normalizeRemoteHost(gatewayHost!) != gatewayHost) {
          _invalid('invalid_settings');
        }
      } catch (_) {
        _invalid('invalid_settings');
      }
    } else if (gatewayUsername.isNotEmpty || gatewayDomain.isNotEmpty) {
      _invalid('invalid_settings');
    }
    fileTransferGrant?.validate();
  }

  Map<String, Object?> toJson() {
    validate();
    return {
      'version': 4,
      'domain': domain,
      'gatewayHost': gatewayHost,
      'gatewayPort': gatewayPort,
      'gatewayUsername': gatewayUsername,
      'gatewayDomain': gatewayDomain,
      'displayMode': displayMode.name,
      'keyboardLayout': keyboardLayout.name,
      'clipboardMode': clipboardMode.name,
      'microphone': microphone,
      'fileTransferGrantId': fileTransferGrant?.id,
      'fileTransferGrantRevision': fileTransferGrant?.revision,
    };
  }

  factory RdpProfileSettings.fromJson(Object? raw) {
    if (raw is! Map || raw['version'] is! int) {
      _invalid('invalid_settings');
    }
    final version = raw['version'] as int;
    final keys = {
      'version',
      'domain',
      'gatewayHost',
      'gatewayPort',
      'gatewayUsername',
      'displayMode',
      'keyboardLayout',
      'clipboardMode',
      if (version >= 2) 'microphone',
      if (version >= 3) ...{'fileTransferGrantId', 'fileTransferGrantRevision'},
      if (version >= 4) 'gatewayDomain',
    };
    if (version < 1 || version > 4) {
      _invalid('invalid_settings');
    }
    final value = _object(raw, keys);
    if (value['domain'] is! String ||
        value['gatewayHost'] != null && value['gatewayHost'] is! String ||
        value['gatewayPort'] is! int ||
        value['gatewayUsername'] is! String ||
        version >= 4 && value['gatewayDomain'] is! String ||
        version >= 2 && value['microphone'] is! bool) {
      _invalid('invalid_settings');
    }
    final grantId = version >= 3 ? value['fileTransferGrantId'] : null;
    final grantRevision = version >= 3
        ? value['fileTransferGrantRevision']
        : null;
    if ((grantId == null) != (grantRevision == null) ||
        grantId != null && grantId is! String ||
        grantRevision != null && grantRevision is! int) {
      _invalid('invalid_settings');
    }
    T parse<T extends Enum>(Object? raw, List<T> values) {
      if (raw is! String) _invalid('invalid_settings');
      return values.where((value) => value.name == raw).firstOrNull ??
          _invalid('invalid_settings');
    }

    RdpDisplayMode parseDisplayMode(Object? raw) {
      // `fixed` was persisted before a real fixed-resolution renderer existed.
      // Migrate it to the truthful contain behavior instead of advertising a
      // mode the product never implemented.
      if (raw == 'fixed') return RdpDisplayMode.fitWindow;
      return parse(raw, RdpDisplayMode.values);
    }

    final result = RdpProfileSettings(
      domain: value['domain'] as String,
      gatewayHost: value['gatewayHost'] as String?,
      gatewayPort: value['gatewayPort'] as int,
      gatewayUsername: value['gatewayUsername'] as String,
      gatewayDomain: version >= 4 ? value['gatewayDomain'] as String : '',
      displayMode: parseDisplayMode(value['displayMode']),
      keyboardLayout: parse(value['keyboardLayout'], RdpKeyboardLayout.values),
      clipboardMode: parse(value['clipboardMode'], RdpClipboardMode.values),
      microphone: version >= 2 ? value['microphone'] as bool : false,
      fileTransferGrant: grantId == null
          ? null
          : RdpFileTransferGrant(
              id: grantId as String,
              revision: grantRevision as int,
            ),
    );
    result.validate();
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is RdpProfileSettings &&
      domain == other.domain &&
      gatewayHost == other.gatewayHost &&
      gatewayPort == other.gatewayPort &&
      gatewayUsername == other.gatewayUsername &&
      gatewayDomain == other.gatewayDomain &&
      displayMode == other.displayMode &&
      keyboardLayout == other.keyboardLayout &&
      clipboardMode == other.clipboardMode &&
      microphone == other.microphone &&
      fileTransferGrant == other.fileTransferGrant;

  @override
  int get hashCode => Object.hash(
    domain,
    gatewayHost,
    gatewayPort,
    gatewayUsername,
    gatewayDomain,
    displayMode,
    keyboardLayout,
    clipboardMode,
    microphone,
    fileTransferGrant,
  );
}

class RdpCredential {
  const RdpCredential({required this.password, this.gatewayPassword = ''});
  final String password, gatewayPassword;

  void validate() {
    for (final value in [password, gatewayPassword]) {
      if (value.length > 4096 ||
          value.contains('\u0000') ||
          value.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff)) {
        _invalid('invalid_credential');
      }
    }
    if (password.isEmpty) _invalid('invalid_credential');
  }

  @override
  String toString() => 'RdpCredential(<redacted>)';

  @override
  bool operator ==(Object other) =>
      other is RdpCredential &&
      password == other.password &&
      gatewayPassword == other.gatewayPassword;
  @override
  int get hashCode => Object.hash(password, gatewayPassword);
}

class RdpChannelPolicy {
  const RdpChannelPolicy({
    this.clipboard = false,
    this.audio = false,
    this.microphone = false,
    this.files = false,
  });
  static const lockedDown = RdpChannelPolicy();
  final bool clipboard, audio, microphone, files;
}

class RdpSessionRequest {
  const RdpSessionRequest({
    required this.profile,
    required this.display,
    required this.certificateFingerprint,
    this.gatewayCertificateFingerprint,
    this.settings = const RdpProfileSettings(),
    this.channels = RdpChannelPolicy.lockedDown,
  });
  final RemoteProfile profile;
  final RdpDisplaySpec display;
  final String certificateFingerprint;
  final String? gatewayCertificateFingerprint;
  final RdpProfileSettings settings;
  final RdpChannelPolicy channels;

  void validate(RdpCapabilities capabilities) {
    settings.validate();
    if (profile.protocol != RemoteProtocol.rdp ||
        profile.username.isEmpty ||
        !capabilities.acceptsDisplay(display) ||
        !capabilities.canConnect ||
        (settings.gatewayHost != null && !capabilities.supportsRdGateway) ||
        !RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$')
            .hasMatch(certificateFingerprint) ||
        (gatewayCertificateFingerprint != null &&
            !RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$')
                .hasMatch(gatewayCertificateFingerprint!)) ||
        channels.clipboard !=
            (settings.clipboardMode != RdpClipboardMode.disabled) ||
        (settings.clipboardMode != RdpClipboardMode.disabled &&
            (!channels.clipboard ||
                !capabilities.supportedClipboardModes.contains(
                  settings.clipboardMode,
                ))) ||
        (channels.audio && !capabilities.supportsAudio) ||
        channels.microphone != settings.microphone ||
        (channels.microphone && !capabilities.supportsMicrophone) ||
        (channels.files && !capabilities.supportsFiles)) {
      _invalid('unsupported_request');
    }
  }
}

/// Geometry of the frame actually decoded, displayed and acknowledged.
class RdpFrameGeometry {
  const RdpFrameGeometry({
    required this.frameSequence,
    required this.width,
    required this.height,
    required this.displayLayoutRevision,
  });
  final int frameSequence, width, height, displayLayoutRevision;
  bool get valid =>
      frameSequence >= 1 &&
      frameSequence <= 9007199254740991 &&
      displayLayoutRevision >= 1 &&
      displayLayoutRevision <= 9007199254740991 &&
      width >= 640 &&
      width <= 8192 &&
      height >= 480 &&
      height <= 8192 &&
      width * height * 4 <= 64 * 1024 * 1024;
  Map<String, Object?> toChannel() => {
    'frameSequence': frameSequence,
    'width': width,
    'height': height,
    'displayLayoutRevision': displayLayoutRevision,
  };
  @override
  bool operator ==(Object other) =>
      other is RdpFrameGeometry &&
      frameSequence == other.frameSequence &&
      width == other.width &&
      height == other.height &&
      displayLayoutRevision == other.displayLayoutRevision;
  @override
  int get hashCode =>
      Object.hash(frameSequence, width, height, displayLayoutRevision);
}

class RdpPointerEvent {
  const RdpPointerEvent({
    required this.x,
    required this.y,
    required this.buttons,
    required this.geometry,
  });
  final double x, y;
  final int buttons;
  final RdpFrameGeometry geometry;
  bool get valid =>
      geometry.valid &&
      x.isFinite &&
      y.isFinite &&
      x >= 0 &&
      x <= 1 &&
      y >= 0 &&
      y <= 1 &&
      buttons >= 0 &&
      buttons <= 7;
}

class RdpRelativePointerEvent {
  const RdpRelativePointerEvent({
    required this.deltaX,
    required this.deltaY,
    required this.buttons,
    required this.geometry,
  });
  final int deltaX, deltaY, buttons;
  final RdpFrameGeometry geometry;
  bool get valid =>
      geometry.valid &&
      deltaX >= -32768 &&
      deltaX <= 32767 &&
      deltaY >= -32768 &&
      deltaY <= 32767 &&
      buttons >= 0 &&
      buttons <= 7;
}

class RdpWheelEvent {
  const RdpWheelEvent({required this.wheelDelta, required this.geometry});
  final int wheelDelta;
  final RdpFrameGeometry geometry;
  bool get valid => geometry.valid && (wheelDelta == 120 || wheelDelta == -120);
}

class RdpKeyEvent {
  const RdpKeyEvent({required this.physicalKey, required this.down});
  final int physicalKey;
  final bool down;
  bool get valid => physicalKey >= 1 && physicalKey <= 0xffffffff;
  bool get supported {
    if (!valid || physicalKey >> 16 != 0x07) return false;
    final usage = physicalKey & 0xffff;
    return usage >= 0x04 && usage <= 0x65 ||
        usage >= 0x67 && usage <= 0x73 ||
        usage >= 0xe0 && usage <= 0xe7;
  }
}
