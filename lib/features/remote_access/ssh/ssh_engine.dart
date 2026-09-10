import 'dart:async';
import 'dart:typed_data';
import '../data/remote_profiles.dart';
import 'ssh_security_store.dart';
abstract class SshChannel {
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<void> get done;
  void write(Uint8List bytes);
  void close();
}
abstract class SshEngine {
  Future<SshChannel> open(RemoteProfile profile,SshCredential credential,{required Future<bool> Function(SshHostPin) verifyHost, required bool Function() isCurrent});
  void close();
}
