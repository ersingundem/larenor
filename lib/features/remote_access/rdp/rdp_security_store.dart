import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/configuration_writes.dart';
import '../data/remote_profiles.dart';
import 'rdp_models.dart';

abstract interface class RdpTrustStore {
  Future<void> checkProfile(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  });
  Future<RdpCertificatePin?> readPin(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  });
  Future<void> trust(
    RemoteProfile profile,
    RdpCertificatePin value, {
    required bool Function() isCurrent,
  });
}

abstract interface class RdpCredentialVault {
  Future<RdpCredential?> readCredential(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  });
  Future<void> saveCredential(
    RemoteProfile profile,
    RdpCredential credential, {
    required bool Function() isCurrent,
  });
  Future<void> deleteCredential(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  });
}

class RdpSecurityStore implements RdpTrustStore, RdpCredentialVault {
  RdpSecurityStore({
    FlutterSecureStorage? storage,
    RemoteProfilesStore? profiles,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _profiles = profiles ?? RemoteProfilesStore();
  final FlutterSecureStorage _storage;
  final RemoteProfilesStore _profiles;

  String reference(RemoteProfile profile) =>
      sha256.convert(utf8.encode(jsonEncode(profile.toJson()))).toString();
  String _key(RemoteProfile profile) =>
      'rdp_certificate_v1_${reference(profile)}';
  String _settingsKey(RemoteProfile profile) =>
      'rdp_settings_v1_${reference(profile)}';
  String _credentialKey(RemoteProfile profile) =>
      'rdp_credential_v1_${reference(profile)}';

  void Function() _guard(bool Function() current) {
    var retired = false;
    return () {
      try {
        if (!retired && current()) return;
      } catch (_) {}
      retired = true;
      throw const RdpFailure('retired');
    };
  }

  Future<void> _profile(RemoteProfile profile, void Function() check) async {
    check();
    final snapshot = await _profiles.read(
      isCurrent: () {
        check();
        return true;
      },
    );
    check();
    if (profile.protocol != RemoteProtocol.rdp ||
        profile.username.isEmpty ||
        !snapshot.profiles.any(
          (value) => reference(value) == reference(profile),
        )) {
      throw const RdpFailure('profile_changed');
    }
  }

  Future<T> _run<T>(
    RemoteProfile profile,
    bool Function() current,
    Future<T> Function(void Function()) action,
  ) {
    final check = _guard(current);
    return ConfigurationWrites.run(() async {
      try {
        await _profile(profile, check);
        final result = await action(check);
        check();
        await _profile(profile, check);
        return result;
      } on RdpFailure {
        rethrow;
      } on RemoteProfilesFailure catch (error) {
        throw RdpFailure(
          error.code == 'retired' ? 'retired' : 'profile_changed',
        );
      } catch (_) {
        check();
        throw const RdpFailure('storage_failed');
      }
    });
  }

  @override
  Future<void> checkProfile(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (_) async {});

  @override
  Future<RdpCertificatePin?> readPin(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (check) async {
    check();
    final raw = await _storage.read(key: _key(profile));
    check();
    if (raw == null) return null;
    if (raw.length > 256) throw const RdpFailure('invalid_record');
    final value = jsonDecode(raw);
    if (value is! Map ||
        value.length != 4 ||
        value['version'] != 1 ||
        value['target'] != reference(profile)) {
      throw const RdpFailure('invalid_record');
    }
    return RdpCertificatePin.fromJson({
      'algorithm': value['algorithm'],
      'fingerprint': value['fingerprint'],
    });
  });

  @override
  Future<void> trust(
    RemoteProfile profile,
    RdpCertificatePin value, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (check) async {
    value.validate();
    final existing = await _storage.read(key: _key(profile));
    check();
    if (existing != null) throw const RdpFailure('certificate_already_pinned');
    final encoded = jsonEncode({
      'version': 1,
      'target': reference(profile),
      'algorithm': value.algorithm,
      'fingerprint': value.fingerprint,
    });
    await _storage.write(key: _key(profile), value: encoded);
    check();
    if (await _storage.read(key: _key(profile)) != encoded) {
      throw const RdpFailure('storage_failed');
    }
  });

  Future<RdpProfileSettings> readSettings(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (check) async {
    final raw = await _storage.read(key: _settingsKey(profile));
    check();
    if (raw == null) return const RdpProfileSettings();
    if (utf8.encode(raw).length > 4096) {
      throw const RdpFailure('invalid_record');
    }
    final value = jsonDecode(raw);
    if (value is! Map ||
        value.length != 3 ||
        value['version'] != 1 ||
        value['target'] != reference(profile)) {
      throw const RdpFailure('invalid_record');
    }
    return RdpProfileSettings.fromJson(value['settings']);
  });

  Future<void> saveSettings(
    RemoteProfile profile,
    RdpProfileSettings settings, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (check) async {
    final encoded = jsonEncode({
      'version': 1,
      'target': reference(profile),
      'settings': settings.toJson(),
    });
    await _storage.write(key: _settingsKey(profile), value: encoded);
    check();
    if (await _storage.read(key: _settingsKey(profile)) != encoded) {
      throw const RdpFailure('storage_failed');
    }
  });

  @override
  Future<RdpCredential?> readCredential(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (check) async {
    final raw = await _storage.read(key: _credentialKey(profile));
    check();
    if (raw == null) return null;
    if (utf8.encode(raw).length > 12288) {
      throw const RdpFailure('invalid_record');
    }
    final value = jsonDecode(raw);
    if (value is! Map ||
        value.length != 4 ||
        value['version'] != 1 ||
        value['target'] != reference(profile) ||
        value['password'] is! String ||
        value['gatewayPassword'] is! String) {
      throw const RdpFailure('invalid_record');
    }
    final result = RdpCredential(
      password: value['password'] as String,
      gatewayPassword: value['gatewayPassword'] as String,
    );
    result.validate();
    return result;
  });

  @override
  Future<void> saveCredential(
    RemoteProfile profile,
    RdpCredential credential, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (check) async {
    credential.validate();
    final encoded = jsonEncode({
      'version': 1,
      'target': reference(profile),
      'password': credential.password,
      'gatewayPassword': credential.gatewayPassword,
    });
    await _storage.write(key: _credentialKey(profile), value: encoded);
    check();
    if (await _storage.read(key: _credentialKey(profile)) != encoded) {
      throw const RdpFailure('storage_failed');
    }
  });

  @override
  Future<void> deleteCredential(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (check) async {
    await _storage.delete(key: _credentialKey(profile));
    check();
    if (await _storage.read(key: _credentialKey(profile)) != null) {
      throw const RdpFailure('storage_failed');
    }
  });
}
