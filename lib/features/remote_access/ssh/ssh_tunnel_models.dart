import 'dart:convert';

import '../data/remote_profiles.dart';
import 'ssh_security_store.dart';

class SshTunnelProfile {
  const SshTunnelProfile._({
    required this.name,
    required this.localPort,
    required this.targetHost,
    required this.targetPort,
  });

  static const loopbackAddress = '127.0.0.1';
  final String name;
  final int localPort;
  final String targetHost;
  final int targetPort;

  static SshTunnelProfile parse({
    required String name,
    required String localPort,
    required String targetHost,
    required String targetPort,
  }) {
    final cleanName = name.trim();
    final local = int.tryParse(localPort.trim());
    final remote = int.tryParse(targetPort.trim());
    if (cleanName.isEmpty ||
        utf8.encode(cleanName).length > 80 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(cleanName) ||
        local == null ||
        local < 1024 ||
        local > 65535 ||
        remote == null ||
        remote < 1 ||
        remote > 65535) {
      throw const SshFailure('invalid_tunnel');
    }
    try {
      return SshTunnelProfile._(
        name: cleanName,
        localPort: local,
        targetHost: normalizeRemoteHost(targetHost),
        targetPort: remote,
      );
    } catch (_) {
      throw const SshFailure('invalid_tunnel');
    }
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'localPort': localPort,
    'targetHost': targetHost,
    'targetPort': targetPort,
  };

  static SshTunnelProfile fromJson(Map<String, dynamic> value) {
    if (value['name'] is! String ||
        value['localPort'] is! int ||
        value['targetHost'] is! String ||
        value['targetPort'] is! int) {
      throw const SshFailure('invalid_record');
    }
    try {
      return parse(
        name: value['name'],
        localPort: '${value['localPort']}',
        targetHost: value['targetHost'],
        targetPort: '${value['targetPort']}',
      );
    } catch (_) {
      throw const SshFailure('invalid_record');
    }
  }

  String get bindAddress => loopbackAddress;
}
