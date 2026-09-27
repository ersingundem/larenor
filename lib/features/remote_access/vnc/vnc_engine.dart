import '../data/remote_profiles.dart';
import '../vnc_framebuffer_surface.dart';
import 'vnc_models.dart';

abstract interface class VncChannel {
  Future<void> get done;
  void pointer(VncPointerEvent event);
  void key(VncKeyEvent event);
  void close();
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
