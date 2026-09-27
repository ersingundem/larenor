import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import '../data/remote_profiles.dart';
import '../vnc_native_bridge.dart';
import '../vnc_framebuffer_surface.dart';
import 'vnc_models.dart';

abstract interface class VncChannel {
  Future<void> get done;
  void pointer(VncPointerEvent event);
  void key(VncKeyEvent event);
  void close();
}

abstract interface class VncInteractiveChannel implements VncChannel {
  void text(String value);
}

/// Optional channel capability implemented only by engines that deliver real
/// bounded RGBA frames and await presentation acknowledgements.
abstract interface class VncFramebufferChannel
    implements VncChannel, VncSurfaceSink {
  Stream<VncRawFrame> get frames;
  bool get clipboardSupported;
}

abstract interface class VncEngine {
  Future<VncCapabilities> capabilities({required bool Function() isCurrent});
  Future<RfbNegotiation> negotiate(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  });
  Future<VncChannel> open(
    VncSessionRequest request, {
    VncSecretLease? password,
    required bool Function() isCurrent,
  });
  void close();
}

/// Product default until a reviewed native RFB engine is packaged. No method
/// performs a DNS lookup or socket operation, and no session is simulated.
class UnsupportedVncEngine implements VncEngine {
  @override
  Future<VncCapabilities> capabilities({
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const VncFailure('retired');
    return VncCapabilities.fromJson(const {
      'schemaVersion': 1,
      'availability': 'unavailable',
      'engineRevision': null,
      'rfbVersions': <String>[],
      'securityTypes': <String>[],
      'security': {
        'tls': false,
        'certificatePinning': false,
        'passwordAuth': false,
      },
      'display': {
        'dynamicResolution': false,
        'externalDisplay': false,
        'maxWidth': 0,
        'maxHeight': 0,
        'maxDpi': 0,
      },
      'input': {'touchpad': false, 'keyboard': false},
      'channels': {'clipboard': false, 'files': false},
    });
  }

  @override
  Future<RfbNegotiation> negotiate(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async => throw const VncFailure('engine_unavailable');

  @override
  Future<VncChannel> open(
    VncSessionRequest request, {
    VncSecretLease? password,
    required bool Function() isCurrent,
  }) async {
    password?.dispose();
    throw const VncFailure('engine_unavailable');
  }

  @override
  void close() {}
}

/// Packaged Android RFB client. Discovery exposes only the peer SPKI for an
/// explicit fingerprint review; the real session must match that accepted pin
/// before any VNC credential or application data is sent.
class VncMethodChannelEngine implements VncEngine {
  VncMethodChannelEngine({
    VncNativeTransport? transport,
    Random? random,
    bool? isAndroid,
  }) : _transport = transport ?? VncMethodChannelTransport(),
       _random = random ?? Random.secure(),
       _isAndroid = isAndroid ?? Platform.isAndroid;

  final VncNativeTransport _transport;
  final Random _random;
  final bool _isAndroid;
  _VncNativeChannel? _active;
  bool _closed = false;

  @override
  Future<VncCapabilities> capabilities({
    required bool Function() isCurrent,
  }) async {
    if (_closed || !_isAndroid || !isCurrent()) {
      return UnsupportedVncEngine().capabilities(isCurrent: isCurrent);
    }
    try {
      final found = await _transport.capabilities();
      if (_closed || !isCurrent()) throw const VncFailure('retired');
      final framebuffer = found.raw['framebuffer'] as Map;
      return VncCapabilities.fromJson({
        'schemaVersion': 1,
        'availability': found.canConnect ? 'available' : 'unavailable',
        'engineRevision': found.canConnect ? found.engineRevision : null,
        'rfbVersions': found.canConnect ? ['3.8'] : <String>[],
        'securityTypes': found.canConnect
            ? ['vencrypt_tls_vnc_auth']
            : <String>[],
        'security': {
          'tls': found.canConnect,
          'certificatePinning': found.canConnect,
          'passwordAuth': found.canConnect,
        },
        'display': {
          'dynamicResolution':
              found.canConnect && framebuffer['dynamicResolution'] == true,
          'externalDisplay':
              found.canConnect && framebuffer['externalDisplay'] == true,
          'maxWidth': found.canConnect ? framebuffer['maxWidth'] : 0,
          'maxHeight': found.canConnect ? framebuffer['maxHeight'] : 0,
          'maxDpi': found.canConnect ? framebuffer['maxDpi'] : 0,
        },
        'input': {
          'touchpad': found.canConnect && found.pointer,
          'keyboard': found.canConnect && found.keyboard,
        },
        'channels': {'clipboard': false, 'files': false},
      });
    } on VncBridgeException catch (failure) {
      throw VncFailure(_failure(failure.code));
    }
  }

  @override
  Future<RfbNegotiation> negotiate(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async {
    if (_closed || !_isAndroid || !isCurrent()) {
      throw const VncFailure('retired');
    }
    try {
      final extended = _transport is VncExtendedNativeTransport
          ? _transport
          : throw const VncFailure('engine_unavailable');
      final pin = await extended.inspectCertificate(profile.host, profile.port);
      if (_closed || !isCurrent()) throw const VncFailure('retired');
      return RfbNegotiation.fromJson({
        'schemaVersion': 1,
        'rfbVersion': '3.8',
        'securityType': 'vencrypt_tls_vnc_auth',
        'tls': true,
        'certificate': {'algorithm': 'spki-sha256', 'fingerprint': pin},
        'requiresPassword': true,
      });
    } on VncBridgeException catch (failure) {
      throw VncFailure(_failure(failure.code));
    }
  }

  @override
  Future<VncChannel> open(
    VncSessionRequest request, {
    VncSecretLease? password,
    required bool Function() isCurrent,
  }) async {
    if (_closed || !_isAndroid || !isCurrent()) {
      throw const VncFailure('retired');
    }
    if (password == null || _active != null) {
      throw const VncFailure('invalid_password');
    }
    final binding = VncSessionBinding.fromChannel({
      'ownerId': _uuid(),
      'accountRevision': 0,
      'routeRevision': 0,
    });
    final bridge = VncBridgeSession(
      transport: _transport,
      binding: binding,
      isCurrent: () => !_closed && isCurrent(),
      isForeground: () => !_closed && isCurrent(),
    );
    final channel = _VncNativeChannel(
      bridge: bridge,
      onClosed: () => _active = null,
    );
    _active = channel;
    final bytes = Uint8List.fromList(password.bytes);
    try {
      final nativeRequest = VncBridgeRequest.fromChannel({
        'schemaVersion': 1,
        'requestId': _uuid(),
        'targetHost': request.profile.host,
        'targetPort': request.profile.port,
        'security': {
          'type': 'vencryptTlsVncAuth',
          'spkiFingerprint': request.certificateFingerprint,
          'requiresPassword': true,
        },
        'display': {
          'width': request.display.width.clamp(640, 2048),
          'height': request.display.height.clamp(480, 2048),
          'dpi': request.display.dpi,
          'externalDisplay': request.display.externalDisplay,
          'dynamicResolution': true,
        },
        'framebuffer': {'encoding': 'raw', 'pixelFormat': 'trueColor32'},
        'input': {'pointer': true, 'keyboard': true, 'clipboard': false},
      });
      await bridge.connect(nativeRequest, bytes);
      if (bridge.phase != VncBridgePhase.connected) {
        throw VncFailure(_failure(bridge.error ?? 'connectionFailed'));
      }
      if (_closed || !isCurrent()) {
        channel.close();
        throw const VncFailure('retired');
      }
      return channel;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      password.dispose();
    }
  }

  String _uuid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _active?.close();
    _active = null;
  }

  static String _failure(String code) => switch (code) {
    'engineUnavailable' => 'engine_unavailable',
    'rfbVersionUnavailable' => 'rfb_version_unsupported',
    'tlsRequired' => 'tls_required',
    'spkiPinningRequired' => 'certificate_changed',
    'authUnavailable' => 'security_unsupported',
    'timedOut' => 'timed_out',
    'staleSession' || 'cancelled' || 'foregroundRequired' => 'retired',
    _ => 'connection_failed',
  };
}

class _VncNativeChannel
    implements
        VncFramebufferChannel,
        VncInteractiveChannel,
        VncResizableSurfaceSink {
  _VncNativeChannel({required this.bridge, required this.onClosed}) {
    _subscription = bridge.frames.listen(
      (notice) => _frames.add(VncRawFrame.fromNotice(notice)),
      onError: _finish,
      onDone: _finish,
      cancelOnError: true,
    );
  }
  final VncBridgeSession bridge;
  final void Function() onClosed;
  final _done = Completer<void>();
  final _frames = StreamController<VncRawFrame>.broadcast(sync: true);
  StreamSubscription<VncFrameNotice>? _subscription;
  bool _closed = false;

  @override
  Future<void> get done => _done.future;
  @override
  Stream<VncRawFrame> get frames => _frames.stream;
  @override
  bool get clipboardSupported => false;
  @override
  Future<void> acknowledge(int sequence) => bridge.ackFrame(sequence);
  @override
  Future<void> input(Map<String, Object?> event) => bridge.input(event);
  @override
  Future<void> cancel() async => close();
  @override
  void pointer(VncPointerEvent event) => unawaited(
    bridge.input({
      'kind': 'pointer',
      'x': event.x,
      'y': event.y,
      'buttons': event.buttons,
    }),
  );
  @override
  void key(VncKeyEvent event) => unawaited(
    bridge.input({
      'kind': 'key',
      'code': event.physicalKey,
      'down': event.down,
    }),
  );
  @override
  void text(String value) =>
      unawaited(bridge.input({'kind': 'text', 'text': value}));
  @override
  Future<void> resize(int width, int height) => bridge.resize(width, height);

  void _finish([Object? error]) {
    if (_closed) return;
    _closed = true;
    if (error == null) {
      if (!_done.isCompleted) _done.complete();
    } else if (!_done.isCompleted) {
      _done.completeError(const VncFailure('connection_lost'));
    }
    unawaited(_frames.close());
    onClosed();
  }

  @override
  void close() {
    if (_closed) return;
    unawaited(bridge.retire());
    unawaited(_subscription?.cancel());
    _subscription = null;
    _finish();
  }
}
