import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum RemoteProtocol { ssh, rdp, vnc }

class RemoteProfile {
  RemoteProfile({required this.id, required this.name, required this.protocol,
    required this.host, required this.port, this.username = ''});
  final String id, name, host, username;
  final RemoteProtocol protocol;
  final int port;
  String get address => throw UnimplementedError();
  Map<String, Object> toJson() => throw UnimplementedError();
  static RemoteProfile fromJson(Object? value) => throw UnimplementedError();
}
String normalizeRemoteHost(String value) => throw UnimplementedError();
int remoteDefaultPort(RemoteProtocol protocol) => throw UnimplementedError();

class RemoteProfilesFailure implements Exception {
  const RemoteProfilesFailure(this.code);
  final String code;
  @override String toString() => 'RemoteProfilesFailure($code)';
}
class RemoteProfilesSnapshot {
  const RemoteProfilesSnapshot(this.raw, this.revision, this.profiles);
  final String? raw;
  final int revision;
  final List<RemoteProfile> profiles;
}
class RemoteProfilesStore {
  RemoteProfilesStore({FlutterSecureStorage? storage});
  static const storageKey = 'remote_profiles_private_v1';
  Future<RemoteProfilesSnapshot> read({required bool Function() isCurrent}) async => throw UnimplementedError();
  Future<RemoteProfilesSnapshot> replace(RemoteProfilesSnapshot before,
    List<RemoteProfile> profiles, {required bool Function() isCurrent}) async => throw UnimplementedError();
}
