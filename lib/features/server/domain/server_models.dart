import 'dart:convert';

import '../../../shared/network/server_bound_client.dart';
import '../../backup/data/backup_snapshot.dart';

/// Deliberately carries no server-provided message, URL, body or credentials.
class LarenorServerException implements Exception {
  const LarenorServerException(this.code);
  final String code;
  @override
  String toString() => 'LarenorServerException($code)';
}

class ServerEndpoint {
  ServerEndpoint(String input) : uri = parseServerUrl(input) {
    // Uri normalizes percent-encoded host characters; inspect the original
    // authority as well so configuration never hides another server spelling.
    final authority = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#]*)')
        .firstMatch(input.trim())
        ?.group(1);
    if (authority == null || authority.contains('%')) {
      throw const FormatException('Invalid server URL.');
    }
  }

  final Uri uri;
  String get baseUrl => uri.toString();

  Uri api(String path) {
    if (!RegExp(r'^/[a-zA-Z0-9/_-]+$').hasMatch(path) || path.contains('//')) {
      throw const LarenorServerException('invalid_request');
    }
    return uri.replace(path: '${uri.path}/api/v1$path');
  }

  @override
  String toString() => 'ServerEndpoint';
}

/// Identity reported by one Core. This value alone grants no session authority.
final class ServerContext {
  const ServerContext._({required this.coreId, required this.homeId});

  factory ServerContext.fromJson(Object? json) {
    final value = serverObject(json);
    final schema = value['schemaVersion'];
    if (value.length != 3 || schema is! int || schema != 1) {
      throw const LarenorServerException('invalid_response');
    }
    String identity(Object? value) {
      if (value is! String ||
          value.length != 32 ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
        throw const LarenorServerException('invalid_response');
      }
      return value;
    }

    return ServerContext._(
      coreId: identity(value['coreId']),
      homeId: identity(value['homeId']),
    );
  }

  int get schemaVersion => 1;
  final String coreId;
  final String homeId;

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'coreId': coreId,
    'homeId': homeId,
  };

  @override
  bool operator ==(Object other) =>
      other is ServerContext &&
      coreId == other.coreId &&
      homeId == other.homeId;

  @override
  int get hashCode => Object.hash(coreId, homeId);

  @override
  String toString() => 'ServerContext';
}

enum ServerRole { admin, member }

class ServerUser {
  const ServerUser({
    required this.id,
    required this.username,
    required this.role,
    required this.mustChangePassword,
  });

  factory ServerUser.fromJson(Map<String, dynamic> json) {
    final role = switch (json['role']) {
      'admin' => ServerRole.admin,
      'member' => ServerRole.member,
      _ => throw const LarenorServerException('invalid_response'),
    };
    if (json['mustChangePassword'] is! bool) {
      throw const LarenorServerException('invalid_response');
    }
    return ServerUser(
      id: serverText(json['id'], max: 128),
      username: serverText(json['username'], max: 128),
      role: role,
      mustChangePassword: json['mustChangePassword'] as bool,
    );
  }

  final String id;
  final String username;
  final ServerRole role;
  final bool mustChangePassword;
  bool get canAdminister => role == ServerRole.admin && !mustChangePassword;

  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    'role': role.name,
    'mustChangePassword': mustChangePassword,
  };
}

/// A session is secret. Never include it in logs, backup snapshots or diagnostics.
class ServerSession {
  const ServerSession({
    required this.endpoint,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.user,
  });

  factory ServerSession.fromResponse(
    ServerEndpoint endpoint,
    Map<String, dynamic> json, {
    required DateTime now,
  }) {
    final expiry = json['expiresIn'];
    if (expiry is! int || expiry < 1 || expiry > 86400) {
      throw const LarenorServerException('invalid_response');
    }
    return ServerSession(
      endpoint: endpoint,
      accessToken: _token(json['accessToken']),
      refreshToken: _token(json['refreshToken']),
      expiresAt: now.add(Duration(seconds: expiry)),
      user: ServerUser.fromJson(serverObject(json['user'])),
    );
  }

  final ServerEndpoint endpoint;
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final ServerUser user;

  bool expiresSoon(DateTime now) =>
      !expiresAt.isAfter(now.add(const Duration(seconds: 30)));

  ServerSession withUser(ServerUser value) => ServerSession(
    endpoint: endpoint,
    accessToken: accessToken,
    refreshToken: refreshToken,
    expiresAt: expiresAt,
    user: value,
  );

  String encodeStorage() => jsonEncode({
    'version': 1,
    'baseUrl': endpoint.baseUrl,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'user': user.toJson(),
  });

  static ServerSession decodeStorage(String encoded) {
    try {
      if (encoded.length > 16384) {
        throw const LarenorServerException('invalid_session');
      }
      final json = serverObject(jsonDecode(encoded));
      if (json['version'] != 1) {
        throw const LarenorServerException('invalid_session');
      }
      return ServerSession(
        endpoint: ServerEndpoint(serverText(json['baseUrl'], max: 2048)),
        accessToken: _token(json['accessToken']),
        refreshToken: _token(json['refreshToken']),
        expiresAt: DateTime.parse(serverText(json['expiresAt'], max: 40)),
        user: ServerUser.fromJson(serverObject(json['user'])),
      );
    } catch (_) {
      throw const LarenorServerException('invalid_session');
    }
  }

  static String _token(Object? value) {
    if (value is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{20,2048}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  @override
  String toString() => 'ServerSession';
}

class ServerVault {
  const ServerVault({required this.revision, required this.snapshot});
  factory ServerVault.fromJson(Map<String, dynamic> json) {
    final revision = json['revision'];
    if (revision is! int || revision < 0 || revision > 9007199254740991) {
      throw const LarenorServerException('invalid_response');
    }
    final document = json['document'];
    if (document == null) {
      return ServerVault(revision: revision, snapshot: null);
    }
    try {
      final wrapper = serverObject(document);
      if (wrapper.length != 2 || wrapper['version'] != 1) {
        throw const LarenorServerException('invalid_response');
      }
      final snapshot = serverObject(wrapper['snapshot']);
      if (snapshot['version'] != 2) {
        throw const LarenorServerException('invalid_response');
      }
      return ServerVault(
        revision: revision,
        snapshot: BackupSnapshot.fromJson(snapshot),
      );
    } catch (_) {
      throw const LarenorServerException('invalid_response');
    }
  }

  final int revision;
  final BackupSnapshot? snapshot;
}

Map<String, dynamic> serverObject(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

String serverText(Object? value, {required int max}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}
