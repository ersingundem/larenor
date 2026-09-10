import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/configuration_writes.dart';

enum RemoteProtocol { ssh, rdp, vnc }

int remoteDefaultPort(RemoteProtocol protocol) => switch (protocol) {
  RemoteProtocol.ssh => 22,
  RemoteProtocol.rdp => 3389,
  RemoteProtocol.vnc => 5900,
};

class RemoteProfilesFailure implements Exception {
  const RemoteProfilesFailure(this.code);
  final String code;
  @override
  String toString() => 'RemoteProfilesFailure($code)';
}

Never _invalid([String code = 'invalid_record']) =>
    throw RemoteProfilesFailure(code);
bool _text(String value, int max, {bool empty = false}) =>
    (empty || value.isNotEmpty) &&
    value.runes.length <= max &&
    value.trim() == value &&
    !value.runes.any(
      (c) =>
          c < 32 ||
          c == 127 ||
          (c >= 0xd800 && c <= 0xdfff) ||
          (c >= 0x202a && c <= 0x202e) ||
          (c >= 0x2066 && c <= 0x2069),
    );

/// No DNS/network lookup. A host is separate from its port and credentials.
/// International DNS names can be entered in their ASCII/punycode form.
String normalizeRemoteHost(String value) {
  var host = value.trim();
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
    if (!host.contains(':')) _invalid('invalid_host');
  }
  if (host.isEmpty ||
      host.length > 253 ||
      RegExp(r'[\s/@\\?#%\[\]]').hasMatch(host)) {
    _invalid('invalid_host');
  }
  final ip = InternetAddress.tryParse(host);
  if (ip != null) {
    if (ip.type == InternetAddressType.IPv4 &&
        (ip.address != host ||
            host
                .split('.')
                .any((part) => part.length > 1 && part.startsWith('0')))) {
      _invalid('invalid_host');
    }
    return ip.address.toLowerCase();
  }
  if (host.contains(':') || RegExp(r'^[0-9.]+$').hasMatch(host)) {
    _invalid('invalid_host');
  }
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  final label = RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$');
  if (host.isEmpty || !host.split('.').every(label.hasMatch)) {
    _invalid('invalid_host');
  }
  return host.toLowerCase();
}

class RemoteProfile {
  const RemoteProfile({
    required this.id,
    required this.name,
    required this.protocol,
    required this.host,
    required this.port,
    this.username = '',
  });
  final String id, name, host, username;
  final RemoteProtocol protocol;
  final int port;
  String get address => '${host.contains(':') ? '[$host]' : host}:$port';
  Map<String, Object> toJson() {
    final value = <String, Object>{
      'id': id,
      'name': name,
      'protocol': protocol.name,
      'host': host,
      'port': port,
      'username': username,
    };
    fromJson(value);
    return value;
  }

  static RemoteProfile fromJson(Object? value) {
    if (value is! Map ||
        value.length != 6 ||
        !value.keys.toSet().containsAll([
          'id',
          'name',
          'protocol',
          'host',
          'port',
          'username',
        ])) {
      _invalid();
    }
    final id = value['id'],
        name = value['name'],
        host = value['host'],
        port = value['port'],
        user = value['username'];
    final protocol = RemoteProtocol.values
        .where((p) => p.name == value['protocol'])
        .firstOrNull;
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        name is! String ||
        !_text(name, 80) ||
        host is! String ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        user is! String ||
        !_text(user, 128, empty: true) ||
        protocol == null) {
      _invalid();
    }
    try {
      if (normalizeRemoteHost(host) != host) _invalid();
    } catch (_) {
      _invalid();
    }
    return RemoteProfile(
      id: id,
      name: name,
      protocol: protocol,
      host: host,
      port: port,
      username: user,
    );
  }
}

class RemoteProfilesSnapshot {
  RemoteProfilesSnapshot(this.raw, this.revision, List<RemoteProfile> profiles)
    : profiles = List.unmodifiable(profiles);
  final String? raw;
  final int revision;
  final List<RemoteProfile> profiles;
}

/// Device-personal metadata, independent of Core/HA/Proxmox. Not a backup key.
/// Each replacement is one bounded secure-storage envelope with a read-set CAS.
class RemoteProfilesStore {
  RemoteProfilesStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  static const storageKey = 'remote_profiles_private_v1';
  static const maxProfiles = 32;
  final FlutterSecureStorage _storage;

  static RemoteProfilesSnapshot _decode(String? raw) {
    if (raw == null) return RemoteProfilesSnapshot(null, 0, []);
    try {
      if (raw.length > 32768 || utf8.encode(raw).length > 32768) _invalid();
      final value = jsonDecode(raw);
      if (value is! Map ||
          value.length != 3 ||
          value['version'] is! int ||
          value['version'] != 1 ||
          value['revision'] is! int ||
          value['revision'] < 0 ||
          value['revision'] > 0x1fffffffffffff ||
          value['profiles'] is! List ||
          (value['profiles'] as List).length > maxProfiles) {
        _invalid();
      }
      final profiles = (value['profiles'] as List)
          .map(RemoteProfile.fromJson)
          .toList();
      if (profiles.map((p) => p.id).toSet().length != profiles.length) {
        _invalid();
      }
      return RemoteProfilesSnapshot(raw, value['revision'] as int, profiles);
    } catch (_) {
      _invalid();
    }
  }

  // Sticky for this operation, including exceptions from a retired widget/ref.
  void Function() _guard(bool Function() current) {
    var retired = false;
    return () {
      try {
        if (!retired && current()) return;
      } catch (_) {
        /* no callback diagnostics */
      }
      retired = true;
      _invalid('retired');
    };
  }

  Future<String?> _read(void Function() check) async {
    check();
    String? raw;
    try {
      raw = await _storage.read(key: storageKey);
    } catch (_) {
      check();
      _invalid('read_failed');
    }
    check();
    return raw;
  }

  Future<RemoteProfilesSnapshot> read({required bool Function() isCurrent}) {
    final check = _guard(isCurrent);
    return ConfigurationWrites.run(() async {
      final raw = await _read(check);
      check();
      final result = _decode(raw);
      check();
      return result;
    });
  }

  Future<RemoteProfilesSnapshot> replace(
    RemoteProfilesSnapshot before,
    List<RemoteProfile> profiles, {
    required bool Function() isCurrent,
  }) {
    final check = _guard(isCurrent);
    // Copy caller-owned list before the queued asynchronous operation starts.
    final frozen = List<RemoteProfile>.unmodifiable(profiles);
    return ConfigurationWrites.run(() async {
      check();
      if (frozen.length > maxProfiles) _invalid('limit');
      final raw = await _read(check);
      check();
      final latest = _decode(raw);
      if (raw != before.raw || latest.revision != before.revision) {
        _invalid('conflict');
      }
      if (latest.revision >= 0x1fffffffffffff) _invalid('limit');
      final encoded = jsonEncode({
        'version': 1,
        'revision': latest.revision + 1,
        'profiles': frozen.map((p) => p.toJson()).toList(),
      });
      final next = _decode(encoded);
      check();
      try {
        await _storage.write(key: storageKey, value: encoded);
      } catch (_) {
        check();
        _invalid('write_unconfirmed');
      }
      check();
      String? confirmed;
      try {
        confirmed = await _storage.read(key: storageKey);
      } catch (_) {
        check();
        _invalid('write_unconfirmed');
      }
      check();
      if (confirmed != encoded) _invalid('write_unconfirmed');
      return next;
    });
  }
}
