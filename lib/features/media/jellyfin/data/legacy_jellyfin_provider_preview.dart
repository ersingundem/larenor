// ignore_for_file: prefer_initializing_formals

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../../core/direct_credential_record.dart';
import '../../../../core/direct_home_access.dart';
import '../../../../shared/network/server_bound_client.dart';

enum LegacyMediaProvider { jellyfin }

/// A secret-free prompt model for an old direct provider connection.
final class LegacyJellyfinProviderPreview {
  const LegacyJellyfinProviderPreview._();

  LegacyMediaProvider get provider => LegacyMediaProvider.jellyfin;

  /// Direct credentials are never copied into a Core provider mapping.
  bool get requiresCredentialReentry => true;

  @override
  String toString() => 'Legacy media provider preview';
}

/// Reads only enough old secure state to offer an explicit transition.
///
/// The complete credential tuple is validated for presence, but no field is
/// returned. Pending or uncertain direct writes remain fail-closed in
/// [DirectCredentialRecord].
final class LegacyJellyfinProviderPreviewReader {
  LegacyJellyfinProviderPreviewReader({
    FlutterSecureStorage? storage,
    DirectHomeAccess? access,
  }) : _access = access,
       _record = DirectCredentialRecord(
         service: DirectCredentialService.jellyfin,
         storage: storage,
         access: access,
       );

  final DirectHomeAccess? _access;
  final DirectCredentialRecord _record;

  void _check(bool Function() isCurrent) {
    _access?.check();
    try {
      if (isCurrent()) return;
    } catch (_) {
      // A throwing route/preview guard is a denial.
    }
    throw StateError('Legacy media provider scope changed');
  }

  Future<LegacyJellyfinProviderPreview?> read({
    required bool Function() isCurrent,
  }) async {
    _check(isCurrent);
    final fields = await _record.readFields();
    _check(isCurrent);
    final baseUrl = fields['baseUrl'];
    final userId = fields['userId'];
    final accessToken = fields['accessToken'];
    if (baseUrl == null ||
        baseUrl.isEmpty ||
        baseUrl.length > 2048 ||
        userId == null ||
        userId.isEmpty ||
        userId.length > 256 ||
        userId.contains(RegExp(r'[\x00-\x1F\x7F]')) ||
        accessToken == null ||
        accessToken.isEmpty ||
        accessToken.length > 4096 ||
        accessToken.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      return null;
    }
    try {
      parseServerUrl(baseUrl);
    } on FormatException {
      return null;
    }
    _check(isCurrent);
    return const LegacyJellyfinProviderPreview._();
  }
}
