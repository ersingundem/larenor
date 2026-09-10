import 'package:flutter/foundation.dart';
import '../data/remote_profiles.dart';
import 'ssh_security_store.dart';
import 'ssh_engine.dart';
enum SshSessionPhase { idle, connecting, hostKey, connected, closed, failed }
class SshSessionController extends ChangeNotifier {
  SshSessionController({required this.profile, required this.store,required this.engineFactory,required this.isCurrent,this.connectTimeout=const Duration(seconds:45)});
  final RemoteProfile profile;
  final SshSecurityStore store;
  final SshEngine Function() engineFactory;
  final bool Function() isCurrent;
  final Duration connectTimeout;
  SshSessionPhase phase=SshSessionPhase.idle;
  SshHostPin? pendingPin;
  String? error;
  String transcript='';
  Future<void> connect() async => throw UnimplementedError();
  Future<void> trustHost() async => throw UnimplementedError();
  Future<void> sendLine(String line) async => throw UnimplementedError();
  void cancel() => throw UnimplementedError();
  void retire() => throw UnimplementedError();
}
