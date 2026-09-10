import '../data/remote_profiles.dart';
class SshFailure implements Exception {
  const SshFailure(this.code);
  final String code;
  @override String toString() => 'SshFailure($code)';
}
enum SshCredentialKind { password, privateKey }
class SshCredential {
  const SshCredential(this.kind, this.secret, {this.passphrase = ''});
  final SshCredentialKind kind;
  final String secret, passphrase;
  @override String toString() => 'SshCredential(redacted)';
}
class SshHostPin {
  const SshHostPin(this.type, this.fingerprint);
  final String type, fingerprint;
}
class SshSecurityStore {
  String reference(RemoteProfile profile) => throw UnimplementedError();
  Future<void> checkProfile(RemoteProfile profile, {required bool Function() isCurrent}) async => throw UnimplementedError();
  Future<void> saveCredential(RemoteProfile profile, SshCredential value, {required bool Function() isCurrent}) async => throw UnimplementedError();
  Future<SshCredential?> readCredential(RemoteProfile profile, {required bool Function() isCurrent}) async => throw UnimplementedError();
  Future<void> forgetCredential(RemoteProfile profile, {required bool Function() isCurrent}) async => throw UnimplementedError();
  Future<SshHostPin?> readPin(RemoteProfile profile, {required bool Function() isCurrent}) async => throw UnimplementedError();
  Future<void> trust(RemoteProfile profile, SshHostPin pin, {required bool Function() isCurrent}) async => throw UnimplementedError();
}
