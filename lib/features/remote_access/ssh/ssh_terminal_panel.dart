import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ssh_engine.dart';
final sshEngineFactoryProvider=Provider<SshEngine Function()>((ref)=>DartSshEngine.new);
