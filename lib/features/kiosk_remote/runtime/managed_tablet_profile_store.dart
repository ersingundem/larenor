import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/configuration_writes.dart';
import '../../server/domain/server_models.dart';
import '../../server/tablet_fleet/domain/server_tablet_fleet_models.dart';
import 'managed_tablet_credential_store.dart';

const managedTabletProfilePreferenceKey = 'managed_tablet_profile_v2';
const managedTabletProfileConfirmationPreferenceKey =
    'managed_tablet_profile_confirmation_v1';

final managedTabletProfileStoreProvider = Provider<ManagedTabletProfileStore>(
  (_) => ManagedTabletProfileStore(
    SharedPreferencesManagedTabletProfilePersistence(),
  ),
);

final managedTabletActiveProfileProvider =
    NotifierProvider<
      ManagedTabletActiveProfileController,
      AppliedManagedTabletProfile?
    >(ManagedTabletActiveProfileController.new);

/// The profile that is allowed to affect this process right now.
///
/// Durable profile bytes are intentionally insufficient: the runtime must
/// first prove that the current account and secure enrollment own them.
final class ManagedTabletActiveProfileController
    extends Notifier<AppliedManagedTabletProfile?> {
  @override
  AppliedManagedTabletProfile? build() => null;

  void activate(AppliedManagedTabletProfile? value) => state = value;
}

final _identity = RegExp(r'^[0-9a-f]{32}$');
final _digest = RegExp(r'^[0-9a-f]{64}$');

final class AppliedManagedTabletProfile {
  const AppliedManagedTabletProfile._({
    required this.authorityFingerprint,
    required this.coreId,
    required this.homeId,
    required this.deviceId,
    required this.deviceRevision,
    required this.revision,
    required this.digest,
    required this.fullscreen,
    required this.idleTimeoutSeconds,
    required this.updatedAt,
    required this.confirmed,
  });

  factory AppliedManagedTabletProfile.fromPublication(
    ManagedTabletEnrollment enrollment,
    ManagedTabletProfilePublication publication,
  ) {
    if (publication.deviceId.isEmpty) {
      throw const LarenorServerException('invalid_response');
    }
    final value = AppliedManagedTabletProfile._(
      authorityFingerprint: _authorityFingerprint(enrollment),
      coreId: enrollment.coreId,
      homeId: enrollment.homeId,
      deviceId: publication.deviceId,
      deviceRevision: publication.deviceRevision,
      revision: publication.revision,
      digest: publication.digest,
      fullscreen: publication.document.fullscreen,
      idleTimeoutSeconds: publication.document.idleTimeoutSeconds,
      updatedAt: publication.updatedAt,
      confirmed: false,
    );
    value._validate();
    return value;
  }

  factory AppliedManagedTabletProfile.fromJson(Object? value) {
    const keys = {
      'schemaVersion',
      'authorityFingerprint',
      'coreId',
      'homeId',
      'deviceId',
      'deviceRevision',
      'revision',
      'digest',
      'fullscreen',
      'idleTimeoutSeconds',
      'updatedAt',
      'confirmed',
    };
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !value.keys.every(keys.contains) ||
        value['schemaVersion'] != 2 ||
        value['authorityFingerprint'] is! String ||
        value['coreId'] is! String ||
        value['homeId'] is! String ||
        value['deviceId'] is! String ||
        value['deviceRevision'] is! int ||
        value['revision'] is! int ||
        value['digest'] is! String ||
        value['fullscreen'] is! bool ||
        value['idleTimeoutSeconds'] is! int ||
        value['updatedAt'] is! num ||
        value['confirmed'] is! bool) {
      throw const FormatException('invalid_managed_tablet_profile');
    }
    final profile = AppliedManagedTabletProfile._(
      authorityFingerprint: value['authorityFingerprint'] as String,
      coreId: value['coreId'] as String,
      homeId: value['homeId'] as String,
      deviceId: value['deviceId'] as String,
      deviceRevision: value['deviceRevision'] as int,
      revision: value['revision'] as int,
      digest: value['digest'] as String,
      fullscreen: value['fullscreen'] as bool,
      idleTimeoutSeconds: value['idleTimeoutSeconds'] as int,
      updatedAt: (value['updatedAt'] as num).toDouble(),
      confirmed: value['confirmed'] as bool,
    );
    try {
      profile._validate();
    } on LarenorServerException {
      throw const FormatException('invalid_managed_tablet_profile');
    }
    return profile;
  }

  final String authorityFingerprint, coreId, homeId, deviceId, digest;
  final int deviceRevision, revision, idleTimeoutSeconds;
  final bool fullscreen;
  final bool confirmed;
  final double updatedAt;

  bool belongsTo(ManagedTabletEnrollment enrollment) =>
      authorityFingerprint == _authorityFingerprint(enrollment) &&
      coreId == enrollment.coreId &&
      homeId == enrollment.homeId &&
      deviceId == enrollment.deviceId;

  Map<String, Object> toJson() => {
    'schemaVersion': 2,
    'authorityFingerprint': authorityFingerprint,
    'coreId': coreId,
    'homeId': homeId,
    'deviceId': deviceId,
    'deviceRevision': deviceRevision,
    'revision': revision,
    'digest': digest,
    'fullscreen': fullscreen,
    'idleTimeoutSeconds': idleTimeoutSeconds,
    'updatedAt': updatedAt,
    'confirmed': confirmed,
  };

  AppliedManagedTabletProfile _confirm() => AppliedManagedTabletProfile._(
    authorityFingerprint: authorityFingerprint,
    coreId: coreId,
    homeId: homeId,
    deviceId: deviceId,
    deviceRevision: deviceRevision,
    revision: revision,
    digest: digest,
    fullscreen: fullscreen,
    idleTimeoutSeconds: idleTimeoutSeconds,
    updatedAt: updatedAt,
    confirmed: true,
  );

  String get _confirmationToken => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            1,
            authorityFingerprint,
            deviceId,
            deviceRevision,
            revision,
            digest,
            updatedAt,
          ]),
        ),
      )
      .toString();

  void _validate() {
    final expected = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              1,
              coreId,
              homeId,
              deviceId,
              fullscreen,
              idleTimeoutSeconds,
            ]),
          ),
        )
        .toString();
    if (!_identity.hasMatch(coreId) ||
        !_identity.hasMatch(homeId) ||
        !_identity.hasMatch(deviceId) ||
        !_digest.hasMatch(authorityFingerprint) ||
        deviceRevision < 1 ||
        revision < 1 ||
        revision > deviceRevision ||
        !_digest.hasMatch(digest) ||
        digest != expected ||
        idleTimeoutSeconds < 30 ||
        idleTimeoutSeconds > 86400 ||
        !updatedAt.isFinite ||
        updatedAt < 0) {
      throw const LarenorServerException('invalid_response');
    }
  }

  static String _authorityFingerprint(ManagedTabletEnrollment enrollment) =>
      sha256
          .convert(
            utf8.encode(
              jsonEncode([
                1,
                enrollment.serverBaseUrl,
                enrollment.coreId,
                enrollment.homeId,
                enrollment.accountId,
                enrollment.deviceId,
                enrollment.pairingId,
                enrollment.revision,
              ]),
            ),
          )
          .toString();

  @override
  String toString() =>
      'AppliedManagedTabletProfile(device: $deviceId, revision: $revision)';
}

abstract interface class ManagedTabletProfilePersistence {
  Future<String?> read();
  Future<void> write(String? value);
  Future<String?> readConfirmation();
  Future<void> writeConfirmation(String? value);
}

final class SharedPreferencesManagedTabletProfilePersistence
    implements ManagedTabletProfilePersistence {
  SharedPreferencesManagedTabletProfilePersistence({
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<String?> read() async =>
      (await _preferences()).getString(managedTabletProfilePreferenceKey);

  @override
  Future<String?> readConfirmation() async => (await _preferences()).getString(
    managedTabletProfileConfirmationPreferenceKey,
  );

  @override
  Future<void> write(String? value) async {
    final preferences = await _preferences();
    final saved = value == null
        ? await preferences.remove(managedTabletProfilePreferenceKey)
        : await preferences.setString(managedTabletProfilePreferenceKey, value);
    if (!saved) throw StateError('managed_tablet_profile_not_persisted');
  }

  @override
  Future<void> writeConfirmation(String? value) async {
    final preferences = await _preferences();
    final saved = value == null
        ? await preferences.remove(
            managedTabletProfileConfirmationPreferenceKey,
          )
        : await preferences.setString(
            managedTabletProfileConfirmationPreferenceKey,
            value,
          );
    if (!saved) throw StateError('managed_tablet_profile_not_confirmed');
  }
}

final class ManagedTabletProfileStore {
  ManagedTabletProfileStore(this.persistence);

  final ManagedTabletProfilePersistence persistence;

  Future<AppliedManagedTabletProfile?> read() async {
    final raw = await persistence.read();
    if (raw == null) return null;
    try {
      final profile = AppliedManagedTabletProfile.fromJson(jsonDecode(raw));
      final confirmation = await persistence.readConfirmation();
      if (!profile.confirmed || confirmation != profile._confirmationToken) {
        throw StateError('managed_tablet_profile_unconfirmed');
      }
      return profile;
    } on FormatException {
      throw StateError('managed_tablet_profile_invalid');
    }
  }

  Future<AppliedManagedTabletProfile?> readFor(
    ManagedTabletEnrollment enrollment,
  ) async {
    final profile = await read();
    return profile?.belongsTo(enrollment) == true ? profile : null;
  }

  Future<AppliedManagedTabletProfile> apply(
    ManagedTabletEnrollment enrollment,
    ManagedTabletProfilePublication publication, {
    required String expectedDeviceId,
    required bool Function() isCurrent,
    Future<void> Function(AppliedManagedTabletProfile? profile)? activate,
  }) => ConfigurationWrites.run(() async {
    if (!isCurrent()) throw StateError('managed_tablet_action_retired');
    if (publication.deviceId != expectedDeviceId) {
      throw StateError('managed_tablet_profile_changed');
    }
    final next = AppliedManagedTabletProfile.fromPublication(
      enrollment,
      publication,
    );
    final previousRaw = await persistence.read();
    final previousConfirmation = await persistence.readConfirmation();
    final previous = previousRaw == null
        ? null
        : AppliedManagedTabletProfile.fromJson(jsonDecode(previousRaw));
    if (!isCurrent()) throw StateError('managed_tablet_action_retired');
    final safePrevious =
        previous?.confirmed == true &&
            previousConfirmation == previous?._confirmationToken &&
            previous?.belongsTo(enrollment) == true
        ? previous
        : null;
    if (safePrevious != null) {
      if (safePrevious.revision > next.revision ||
          (safePrevious.revision == next.revision &&
              safePrevious.digest != next.digest)) {
        throw StateError('managed_tablet_profile_changed');
      }
      if (safePrevious.revision == next.revision) {
        if (activate != null) await activate(safePrevious);
        return safePrevious;
      }
    }
    await persistence.write(jsonEncode(next.toJson()));
    var confirmationPublished = false;
    try {
      if (!isCurrent()) throw StateError('managed_tablet_action_retired');
      if (activate != null) await activate(next);
      if (!isCurrent()) throw StateError('managed_tablet_action_retired');
      final committed = next._confirm();
      await persistence.write(jsonEncode(committed.toJson()));
      if (!isCurrent()) throw StateError('managed_tablet_action_retired');
      await persistence.writeConfirmation(committed._confirmationToken);
      confirmationPublished = true;
      if (!isCurrent()) throw StateError('managed_tablet_action_retired');
      return committed;
    } catch (error, stackTrace) {
      Object? rollbackFailure;
      var documentRestored = false;
      var confirmationCleared = false;
      if (confirmationPublished) {
        try {
          await persistence.writeConfirmation(null);
          confirmationCleared = true;
        } catch (rollbackError) {
          rollbackFailure = rollbackError;
        }
      }
      try {
        await persistence.write(safePrevious == null ? null : previousRaw);
        documentRestored = true;
      } catch (rollbackError) {
        rollbackFailure ??= rollbackError;
      }
      if (documentRestored) {
        final confirmationToRestore = safePrevious == null
            ? null
            : previousConfirmation;
        if (confirmationToRestore != null ||
            (!confirmationCleared && previousConfirmation != null)) {
          try {
            await persistence.writeConfirmation(confirmationToRestore);
          } catch (rollbackError) {
            rollbackFailure ??= rollbackError;
          }
        }
      }
      try {
        if (activate != null) await activate(safePrevious);
      } catch (rollbackError) {
        rollbackFailure ??= rollbackError;
      }
      if (rollbackFailure != null) {
        Error.throwWithStackTrace(
          StateError('managed_tablet_profile_rollback_failed'),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  });
}
