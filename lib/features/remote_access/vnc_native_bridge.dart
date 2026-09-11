import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class VncBridgeException implements Exception {
  const VncBridgeException(this.code);
  final String code;
  @override
  String toString() => 'VncBridgeException($code)';
}

Never _invalid([String code = 'invalidResponse']) =>
    throw VncBridgeException(code);

Map<Object?, Object?> _map(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    _invalid();
  }
  return raw;
}

int _integer(Object? raw, {int min = 0, int max = 0x1fffffffffffff}) {
  if (raw is! int || raw < min || raw > max) _invalid();
  return raw;
}

bool _boolean(Object? raw) {
  if (raw is! bool) _invalid();
  return raw;
}

String _text(Object? raw, int min, int max) {
  if (raw is! String ||
      raw.length < min ||
      raw.length > max ||
      raw.trim() != raw ||
      raw.runes.any(
        (value) =>
            value < 32 ||
            value == 127 ||
            value >= 0x202a && value <= 0x202e ||
            value >= 0x2066 && value <= 0x2069,
      )) {
    _invalid();
  }
  return raw;
}

class VncSessionBinding {
  const VncSessionBinding._({
    required this.ownerId,
    required this.accountRevision,
    required this.routeRevision,
  });
  final String ownerId;
  final int accountRevision, routeRevision;

  factory VncSessionBinding.fromChannel(Object? raw) {
    final value = _map(raw, {'ownerId', 'accountRevision', 'routeRevision'});
    final owner = _text(value['ownerId'], 36, 36);
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(owner)) {
      _invalid();
    }
    return VncSessionBinding._(
      ownerId: owner,
      accountRevision: _integer(value['accountRevision']),
      routeRevision: _integer(value['routeRevision']),
    );
  }

  Map<String, Object> toChannel() => {
    'ownerId': ownerId,
    'accountRevision': accountRevision,
    'routeRevision': routeRevision,
  };

  bool matches(Object? raw) {
    try {
      final other = VncSessionBinding.fromChannel(raw);
      return ownerId == other.ownerId &&
          accountRevision == other.accountRevision &&
          routeRevision == other.routeRevision;
    } catch (_) {
      return false;
    }
  }
}

class VncBridgeCapabilities {
  const VncBridgeCapabilities._({
    required this.canConnect,
    required this.engineRevision,
    required this.raw,
  });
  final bool canConnect;
  final String? engineRevision;
  final Map<Object?, Object?> raw;

  factory VncBridgeCapabilities.fromChannel(Object? raw) {
    final value = _map(raw, {
      'schemaVersion',
      'availability',
      'engineRevision',
      'rfbVersions',
      'securityTypes',
      'transport',
      'auth',
      'framebuffer',
      'input',
    });
    if (value['schemaVersion'] != 1 ||
        !{'available', 'unavailable'}.contains(value['availability'])) {
      _invalid();
    }
    final available = value['availability'] == 'available';
    final revision = value['engineRevision'];
    if (available) {
      final parsed = _text(revision, 1, 64);
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$').hasMatch(parsed)) {
        _invalid();
      }
    } else if (revision != null) {
      _invalid();
    }
    final versions = _stringSet(value['rfbVersions'], {'3.8'});
    final security = _stringSet(value['securityTypes'], {
      'vencryptTlsVncAuth',
      'vncAuth',
      'none',
    });
    final transport = _map(value['transport'], {'tls', 'spkiPinning'});
    final auth = _map(value['auth'], {'password'});
    final framebuffer = _map(value['framebuffer'], {
      'encodings',
      'trueColor32',
      'dynamicResolution',
      'externalDisplay',
      'maxWidth',
      'maxHeight',
      'maxDpi',
    });
    final encodings = _stringSet(framebuffer['encodings'], {
      'tight',
      'zrle',
      'raw',
    });
    final inputMap = _map(value['input'], {'pointer', 'keyboard', 'clipboard'});
    final tls = _boolean(transport['tls']);
    final pin = _boolean(transport['spkiPinning']);
    final password = _boolean(auth['password']);
    final trueColor = _boolean(framebuffer['trueColor32']);
    final dynamicResolution = _boolean(framebuffer['dynamicResolution']);
    final externalDisplay = _boolean(framebuffer['externalDisplay']);
    final width = _integer(framebuffer['maxWidth'], max: 8192);
    final height = _integer(framebuffer['maxHeight'], max: 8192);
    final dpi = _integer(framebuffer['maxDpi'], max: 640);
    final pointer = _boolean(inputMap['pointer']);
    final keyboard = _boolean(inputMap['keyboard']);
    final clipboard = _boolean(inputMap['clipboard']);
    if (!available &&
        (versions.isNotEmpty ||
            security.isNotEmpty ||
            tls ||
            pin ||
            password ||
            encodings.isNotEmpty ||
            trueColor ||
            dynamicResolution ||
            externalDisplay ||
            width != 0 ||
            height != 0 ||
            dpi != 0 ||
            pointer ||
            keyboard ||
            clipboard)) {
      _invalid();
    }
    return VncBridgeCapabilities._(
      canConnect:
          available &&
          versions.contains('3.8') &&
          security.contains('vencryptTlsVncAuth') &&
          tls &&
          pin &&
          password &&
          trueColor &&
          pointer &&
          keyboard &&
          width >= 640 &&
          height >= 480 &&
          dpi >= 72,
      engineRevision: revision as String?,
      raw: Map.unmodifiable(value),
    );
  }

  static Set<String> _stringSet(Object? raw, Set<String> allowed) {
    if (raw is! List || raw.length > allowed.length) _invalid();
    final values = raw.whereType<String>().toSet();
    if (values.length != raw.length || !allowed.containsAll(values)) _invalid();
    return values;
  }
}

class VncBridgeRequest {
  VncBridgeRequest._(this._raw, this.requestId);
  final Map<String, Object?> _raw;
  final String requestId;

  factory VncBridgeRequest.fromChannel(Object? raw) {
    final root = _map(raw, {
      'schemaVersion',
      'requestId',
      'targetHost',
      'targetPort',
      'security',
      'display',
      'framebuffer',
      'input',
    });
    if (root['schemaVersion'] != 1) _invalid('invalidRequest');
    final id = _text(root['requestId'], 36, 36);
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(id)) {
      _invalid('invalidRequest');
    }
    final host = _text(root['targetHost'], 1, 253);
    if (RegExp(r'[\s/@\\?#%\[\]]').hasMatch(host)) _invalid('invalidRequest');
    _integer(root['targetPort'], min: 1, max: 65535);
    final security = _map(root['security'], {
      'type',
      'spkiFingerprint',
      'requiresPassword',
    });
    if (security['type'] != 'vencryptTlsVncAuth' ||
        security['requiresPassword'] != true ||
        security['spkiFingerprint'] is! String ||
        !RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$')
            .hasMatch(security['spkiFingerprint'] as String)) {
      _invalid('invalidRequest');
    }
    final display = _map(root['display'], {
      'width',
      'height',
      'dpi',
      'externalDisplay',
      'dynamicResolution',
    });
    final width = _integer(display['width'], min: 640, max: 8192);
    final height = _integer(display['height'], min: 480, max: 8192);
    if (width * height > 33554432) _invalid('invalidRequest');
    _integer(display['dpi'], min: 72, max: 640);
    _boolean(display['externalDisplay']);
    _boolean(display['dynamicResolution']);
    final framebuffer = _map(root['framebuffer'], {'encoding', 'pixelFormat'});
    if (!{'tight', 'zrle', 'raw'}.contains(framebuffer['encoding']) ||
        framebuffer['pixelFormat'] != 'trueColor32') {
      _invalid('invalidRequest');
    }
    final input = _map(root['input'], {'pointer', 'keyboard', 'clipboard'});
    _boolean(input['pointer']);
    _boolean(input['keyboard']);
    _boolean(input['clipboard']);
    return VncBridgeRequest._(
      Map<String, Object?>.unmodifiable(root.cast<String, Object?>()),
      id,
    );
  }

  Map<String, Object?> toChannel() => _raw;
  @override
  String toString() => 'VncBridgeRequest(<redacted>)';
}

class VncOpenedSession {
  const VncOpenedSession({required this.sessionId, required this.requestId});
  final String sessionId, requestId;

  factory VncOpenedSession.fromChannel(Object? raw) {
    final value = _map(raw, {'sessionId', 'requestId'});
    final session = _text(value['sessionId'], 36, 36);
    final request = _text(value['requestId'], 36, 36);
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );
    if (session != request || !uuid.hasMatch(session)) _invalid();
    return VncOpenedSession(sessionId: session, requestId: request);
  }
}

class VncFrameNotice {
  const VncFrameNotice({
    required this.sequence,
    required this.width,
    required this.height,
    required this.byteLength,
  });
  final int sequence, width, height, byteLength;

  factory VncFrameNotice.fromChannel(
    Object? raw,
    VncSessionBinding binding,
    String sessionId,
  ) {
    final value = _map(raw, {
      'ownerId',
      'accountRevision',
      'routeRevision',
      'sessionId',
      'sequence',
      'width',
      'height',
      'byteLength',
    });
    if (!binding.matches({
          'ownerId': value['ownerId'],
          'accountRevision': value['accountRevision'],
          'routeRevision': value['routeRevision'],
        }) ||
        value['sessionId'] != sessionId) {
      _invalid('staleSession');
    }
    final width = _integer(value['width'], min: 640, max: 8192);
    final height = _integer(value['height'], min: 480, max: 8192);
    final bytes = _integer(value['byteLength'], min: 1, max: 16 * 1024 * 1024);
    if (bytes > width * height * 4) _invalid();
    return VncFrameNotice(
      sequence: _integer(value['sequence'], min: 1),
      width: width,
      height: height,
      byteLength: bytes,
    );
  }
}

abstract interface class VncNativeTransport {
  Stream<Object?> get frameEvents;
  Future<void> activate(VncSessionBinding binding);
  Future<VncBridgeCapabilities> capabilities();
  Future<VncOpenedSession> open(
    VncSessionBinding binding,
    VncBridgeRequest request,
    Uint8List password,
    String expectedEngineRevision,
  );
  Future<void> cancel(VncSessionBinding binding);
  Future<void> input(
    VncSessionBinding binding,
    int sequence,
    Map<String, Object?> event,
  );
  Future<void> ackFrame(VncSessionBinding binding, int sequence);
}

class VncMethodChannelTransport implements VncNativeTransport {
  VncMethodChannelTransport({
    MethodChannel? methods,
    EventChannel? events,
    bool? isAndroid,
  }) : _methods = methods ?? const MethodChannel(methodChannelName),
       _events = events ?? const EventChannel(eventChannelName),
       _isAndroid =
           isAndroid ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);
  static const methodChannelName = 'com.ersingundem.larenor/vnc_native';
  static const eventChannelName = 'com.ersingundem.larenor/vnc_native_frames';
  final MethodChannel _methods;
  final EventChannel _events;
  final bool _isAndroid;

  @override
  Stream<Object?> get frameEvents =>
      !_isAndroid ? const Stream.empty() : _safeEvents();

  Stream<Object?> _safeEvents() async* {
    try {
      await for (final event in _events.receiveBroadcastStream()) {
        yield event;
      }
    } on PlatformException catch (error) {
      throw _safeError(error.code);
    } catch (_) {
      throw const VncBridgeException('connectionFailed');
    }
  }

  @override
  Future<void> activate(VncSessionBinding binding) =>
      _call<void>('activate', arguments: binding.toChannel());

  @override
  Future<VncBridgeCapabilities> capabilities() async =>
      VncBridgeCapabilities.fromChannel(await _call<Object?>('capabilities'));

  @override
  Future<VncOpenedSession> open(
    VncSessionBinding binding,
    VncBridgeRequest request,
    Uint8List password,
    String expectedEngineRevision,
  ) async {
    try {
      return VncOpenedSession.fromChannel(
        await _call<Object?>(
          'open',
          arguments: {
            'binding': binding.toChannel(),
            'request': request.toChannel(),
            'expectedEngineRevision': expectedEngineRevision,
            'password': password,
          },
          timeout: const Duration(seconds: 45),
        ),
      );
    } finally {
      password.fillRange(0, password.length, 0);
    }
  }

  @override
  Future<void> cancel(VncSessionBinding binding) =>
      _call<void>('cancel', arguments: binding.toChannel());

  @override
  Future<void> input(
    VncSessionBinding binding,
    int sequence,
    Map<String, Object?> event,
  ) => _call<void>(
    'input',
    arguments: {
      'binding': binding.toChannel(),
      'sequence': sequence,
      'event': event,
    },
  );

  @override
  Future<void> ackFrame(VncSessionBinding binding, int sequence) => _call<void>(
    'ackFrame',
    arguments: {'binding': binding.toChannel(), 'sequence': sequence},
  );

  Future<T?> _call<T>(
    String method, {
    Object? arguments,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!_isAndroid) throw const VncBridgeException('engineUnavailable');
    try {
      return await _methods.invokeMethod<T>(method, arguments).timeout(timeout);
    } on MissingPluginException {
      throw const VncBridgeException('engineUnavailable');
    } on PlatformException catch (error) {
      throw _safeError(error.code);
    } on TimeoutException {
      throw const VncBridgeException('timedOut');
    }
  }

  VncBridgeException _safeError(String code) =>
      VncBridgeException(_safeCodes.contains(code) ? code : 'connectionFailed');

  static const _safeCodes = {
    'invalidRequest',
    'invalidSecrets',
    'engineUnavailable',
    'rfbVersionUnavailable',
    'tlsRequired',
    'spkiPinningRequired',
    'authUnavailable',
    'framebufferUnavailable',
    'inputUnavailable',
    'foregroundRequired',
    'busy',
    'timedOut',
    'cancelled',
    'staleSession',
    'connectionFailed',
  };
}

enum VncBridgePhase {
  idle,
  checking,
  unsupported,
  connecting,
  connected,
  retired,
  failed,
}

class VncBridgeSession {
  VncBridgeSession({
    required this.transport,
    required this.binding,
    required this.isCurrent,
    required this.isForeground,
  });
  final VncNativeTransport transport;
  final VncSessionBinding binding;
  final bool Function() isCurrent, isForeground;
  VncBridgePhase phase = VncBridgePhase.idle;
  VncFrameNotice? pendingFrame;
  String? error;
  VncOpenedSession? _opened;
  StreamSubscription<Object?>? _frames;
  bool _activated = false, _cancelled = false, _inputBusy = false;
  int _inputSequence = 0, _frameSequence = 0;

  bool get _ownsSession {
    try {
      return isCurrent() && isForeground();
    } catch (_) {
      return false;
    }
  }

  Future<void> connect(VncBridgeRequest request, Uint8List password) async {
    if (phase != VncBridgePhase.idle) {
      password.fillRange(0, password.length, 0);
      throw const VncBridgeException('busy');
    }
    if (!_ownsSession) {
      password.fillRange(0, password.length, 0);
      phase = VncBridgePhase.retired;
      return;
    }
    phase = VncBridgePhase.checking;
    try {
      await transport.activate(binding);
      _activated = true;
      if (!await _guard()) return;
      final capabilities = await transport.capabilities();
      if (!await _guard()) return;
      if (!capabilities.canConnect) {
        phase = VncBridgePhase.unsupported;
        await _cancelOnce();
        return;
      }
      _frames = transport.frameEvents.listen(
        _onFrame,
        onError: (_) => unawaited(_retire()),
        onDone: () => unawaited(_retire()),
      );
      phase = VncBridgePhase.connecting;
      final revision = capabilities.engineRevision;
      if (revision == null) throw const VncBridgeException('invalidResponse');
      final opened = await transport.open(binding, request, password, revision);
      if (!await _guard()) return;
      if (opened.requestId != request.requestId) {
        throw const VncBridgeException('staleSession');
      }
      _opened = opened;
      phase = VncBridgePhase.connected;
    } on VncBridgeException catch (failure) {
      if (phase != VncBridgePhase.retired) {
        error = failure.code;
        phase = VncBridgePhase.failed;
        await _cancelOnce();
      }
    } catch (_) {
      if (phase != VncBridgePhase.retired) {
        error = 'connectionFailed';
        phase = VncBridgePhase.failed;
        await _cancelOnce();
      }
    } finally {
      password.fillRange(0, password.length, 0);
    }
  }

  Future<bool> _guard() async {
    if (_ownsSession) return true;
    await _retire();
    return false;
  }

  void _onFrame(Object? raw) {
    if (phase != VncBridgePhase.connected ||
        !_ownsSession ||
        pendingFrame != null) {
      unawaited(_retire());
      return;
    }
    try {
      final opened = _opened ?? _invalid('staleSession');
      final frame = VncFrameNotice.fromChannel(raw, binding, opened.sessionId);
      if (frame.sequence != _frameSequence + 1) _invalid('staleSession');
      pendingFrame = frame;
    } catch (_) {
      unawaited(_retire());
    }
  }

  Future<void> ackFrame(int sequence) async {
    final frame = pendingFrame;
    if (phase != VncBridgePhase.connected ||
        !_ownsSession ||
        frame == null ||
        frame.sequence != sequence) {
      await _retire();
      throw const VncBridgeException('staleSession');
    }
    try {
      await transport.ackFrame(binding, sequence);
      if (!await _guard()) return;
      _frameSequence = sequence;
      pendingFrame = null;
    } catch (_) {
      await _retire();
      rethrow;
    }
  }

  Future<void> input(Map<String, Object?> event) async {
    if (phase != VncBridgePhase.connected || !_ownsSession) {
      await _retire();
      throw const VncBridgeException('retired');
    }
    _validateInput(event);
    if (_inputBusy) throw const VncBridgeException('busy');
    _inputBusy = true;
    final sequence = _inputSequence + 1;
    try {
      await transport.input(binding, sequence, event);
      if (!await _guard()) return;
      _inputSequence = sequence;
    } catch (_) {
      await _retire();
      rethrow;
    } finally {
      _inputBusy = false;
    }
  }

  void _validateInput(Map<String, Object?> event) {
    if (event['kind'] == 'key') {
      if (event.keys.toSet().difference({'kind', 'code', 'down'}).isNotEmpty ||
          event.length != 3 ||
          event['code'] is! int ||
          !(event['code'] as int).inRange(1, 0xffff) ||
          event['down'] is! bool) {
        _invalid('invalidRequest');
      }
      return;
    }
    if (event['kind'] == 'pointer') {
      if (event.keys.toSet().difference({
            'kind',
            'x',
            'y',
            'buttons',
          }).isNotEmpty ||
          event.length != 4 ||
          event['x'] is! num ||
          event['y'] is! num ||
          !(event['x'] as num).isFinite ||
          !(event['y'] as num).isFinite ||
          (event['x'] as num) < 0 ||
          (event['x'] as num) > 1 ||
          (event['y'] as num) < 0 ||
          (event['y'] as num) > 1 ||
          event['buttons'] is! int ||
          !(event['buttons'] as int).inRange(0, 31)) {
        _invalid('invalidRequest');
      }
      return;
    }
    _invalid('invalidRequest');
  }

  Future<void> synchronize() async {
    if (!_ownsSession) await _retire();
  }

  Future<void> _retire() async {
    if (phase == VncBridgePhase.retired) return;
    phase = VncBridgePhase.retired;
    pendingFrame = null;
    await _frames?.cancel();
    _frames = null;
    await _cancelOnce();
    _opened = null;
  }

  Future<void> _cancelOnce() async {
    if (_cancelled || !_activated) return;
    _cancelled = true;
    try {
      await transport.cancel(binding);
    } catch (_) {
      // Cleanup is terminal. It is never retried or exposed with native detail.
    }
  }
}

extension on int {
  bool inRange(int min, int max) => this >= min && this <= max;
}
