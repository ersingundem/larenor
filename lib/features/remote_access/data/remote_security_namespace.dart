import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Non-secret ownership namespace for device-secure remote access records.
///
/// The encoded identity deliberately matches the established SSH v2 format.
/// Protocol stores keep distinct key prefixes, while the common digest binds
/// each record to either the device-local registry or one exact Core source.
final class RemoteSecurityNamespace {
  RemoteSecurityNamespace._(this.digest, {required this.allowsLegacyLocal});

  factory RemoteSecurityNamespace.local() => RemoteSecurityNamespace._(
    sha256
        .convert(utf8.encode('{"schemaVersion":1,"source":"local"}'))
        .toString(),
    allowsLegacyLocal: true,
  );

  factory RemoteSecurityNamespace.coreManaged({
    required String endpoint,
    required String coreId,
    required String homeId,
    required String accountId,
    required String sessionFamilyId,
  }) {
    final uri = Uri.tryParse(endpoint);
    final identity = RegExp(r'^[0-9a-f]{32}$');
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        endpoint != uri.toString() ||
        !identity.hasMatch(coreId) ||
        !identity.hasMatch(homeId) ||
        !identity.hasMatch(accountId) ||
        !identity.hasMatch(sessionFamilyId)) {
      throw const FormatException('Invalid remote security namespace.');
    }
    final encoded = jsonEncode({
      'schemaVersion': 1,
      'source': 'coreManaged',
      'endpoint': endpoint,
      'coreId': coreId,
      'homeId': homeId,
      'accountId': accountId,
      'sessionFamilyId': sessionFamilyId,
    });
    return RemoteSecurityNamespace._(
      sha256.convert(utf8.encode(encoded)).toString(),
      allowsLegacyLocal: false,
    );
  }

  final String digest;
  final bool allowsLegacyLocal;

  @override
  String toString() => 'RemoteSecurityNamespace(redacted)';
}
