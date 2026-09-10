import '../data/remote_profiles.dart';
import 'rdp_models.dart';

abstract interface class RdpChannel {
  Future<void> get done;
  void pointer(RdpPointerEvent event);
  void key(RdpKeyEvent event);
  void resize(RdpDisplaySpec display);
  void close();
}

abstract interface class RdpEngine {
  Future<RdpCapabilities> capabilities({required bool Function() isCurrent});
  Future<RdpPeerSecurity> inspect(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  });
  Future<RdpChannel> open(
    RdpSessionRequest request, {
    required RdpCredential? credential,
    required bool Function() isCurrent,
  });
  void close();
}

/// Product default until a reviewed native engine is packaged. It performs no
/// DNS lookup or socket operation and exposes no pretend session capability.
class UnsupportedRdpEngine implements RdpEngine {
  @override
  Future<RdpCapabilities> capabilities({
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const RdpFailure('retired');
    return RdpCapabilities.fromJson(const {
      'schemaVersion': 1,
      'availability': 'unavailable',
      'engineRevision': null,
      'security': {'tls': false, 'certificatePinning': false, 'nla': false},
      'display': {
        'dynamicResolution': false,
        'externalDisplay': false,
        'maxWidth': 0,
        'maxHeight': 0,
        'maxDpi': 0,
      },
      'input': {'touchpad': false, 'keyboard': false},
      'channels': {'clipboard': false, 'audio': false, 'files': false},
    });
  }

  @override
  Future<RdpPeerSecurity> inspect(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) => throw const RdpFailure('engine_unavailable');
  @override
  Future<RdpChannel> open(
    RdpSessionRequest request, {
    required RdpCredential? credential,
    required bool Function() isCurrent,
  }) => throw const RdpFailure('engine_unavailable');
  @override
  void close() {}
}
