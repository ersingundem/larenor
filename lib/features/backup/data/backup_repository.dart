import 'dart:convert';

import '../../../core/configuration_writes.dart';
import '../../intercom/domain/door_station.dart';
import '../../settings/domain/screen_program.dart';
import '../../wellbeing/data/wellbeing_store.dart';
import '../../wellbeing/data/wellbeing_disclosure_policy.dart';
import 'backup_snapshot.dart';
import 'backup_storage.dart';

class BackupRepository {
  BackupRepository({BackupStorage? storage, DateTime Function()? now})
    : _storage = storage ?? PlatformBackupStorage(),
      _now = now ?? DateTime.now;
  final BackupStorage _storage;
  final DateTime Function() _now;
  static const restoreJournalKey = 'backup_restore_journal_v1';
  static const _dashboardKey = 'dashboard_layout';
  static const _migrationKey = 'enabled_services_migrated';
  static const _maxJournalBytes = 8 * 1024 * 1024;

  Future<BackupSnapshot> capture(BackupSelection selection) =>
      ConfigurationWrites.run(() async {
        if (selection.isEmpty) {
          throw const BackupValidationException(
            'Select at least one backup group.',
          );
        }
        await _requireRecovered();
        try {
          final groups = <String, dynamic>{};
          final policy = WellbeingDisclosurePolicy.decode(
            await _storage.readSecret(WellbeingDisclosureStore.storageKey),
          );
          final privateRaw = await _storage.readSecret(
            WellbeingStore.storageKey,
          );
          if (privateRaw != null && privateRaw.length > 32768) {
            throw const BackupValidationException();
          }
          final privateSettings = privateRaw == null
              ? null
              : WellbeingStore.decode(jsonDecode(privateRaw));
          groups['privacy'] = WellbeingDisclosurePolicy.fromJson(
            WellbeingDisclosurePolicy(
              entityIds: {
                ...policy.entityIds,
                ...?privateSettings?.bindings.map((v) => v.entityId),
              },
              reviewRequired: policy.reviewRequired,
            ).toJson(),
          ).toJson();
          if (selection.settings) {
            groups['settings'] = <String, dynamic>{
              for (final key in backupPreferenceKeys)
                key: await _storage.readPreference(key),
            };
          }
          if (selection.dashboard) {
            final raw = await _storage.readPreference(_dashboardKey);
            groups['dashboard'] = raw == null
                ? <String, dynamic>{
                    'rooms': [],
                    'tiles': [],
                    'favoriteEntityIds': [],
                    'hiddenEntityIds': [],
                  }
                : jsonDecode(raw as String);
          }
          if (selection.connections) {
            final records = <String, dynamic>{};
            for (final service in backupConnectionFields.keys) {
              final record = await _readConnection(service);
              if (record != null) records[service] = record;
            }
            groups['connections'] = records;
          }
          return BackupSnapshot.fromJson({
            'version': 2,
            'createdAt': _now().toUtc().toIso8601String(),
            'groups': groups,
          });
        } on BackupException {
          rethrow;
        } catch (_) {
          throw const BackupException(
            'storage_failed',
            'The selected configuration could not be read.',
          );
        }
      });

  Future<BackupPreview> preview(
    BackupSnapshot snapshot,
  ) => ConfigurationWrites.run(() async {
    await _requireRecovered();
    final json = snapshot.toJson();
    validateBackupJson(json);
    final groups = json['groups'] as Map<String, dynamic>;
    final settings = groups['settings'] as Map<String, dynamic>? ?? {};
    final dashboard = groups['dashboard'] as Map<String, dynamic>? ?? {};
    final connections = groups['connections'] as Map<String, dynamic>? ?? {};
    final privacy = groups['privacy'] == null
        ? null
        : WellbeingDisclosurePolicy.fromJson(groups['privacy']);
    try {
      var existingSettings = 0;
      for (final key in settings.keys) {
        if (await _storage.readPreference(key) != null) existingSettings++;
      }
      final existingServices = <String>[];
      for (final service in connections.keys) {
        if (await _hasConnection(service)) existingServices.add(service);
      }
      return BackupPreview(
        createdAt: snapshot.createdAt,
        hasSettings: snapshot.hasSettings,
        hasDashboard: snapshot.hasDashboard,
        hasConnections: snapshot.hasConnections,
        settingCount: settings.values.where((value) => value != null).length,
        roomCount: (dashboard['rooms'] as List? ?? []).length,
        tileCount: (dashboard['tiles'] as List? ?? []).length,
        favoriteCount: (dashboard['favoriteEntityIds'] as List? ?? []).length,
        services: List.unmodifiable(connections.keys),
        existingSettingsCount: existingSettings,
        existingDashboard:
            snapshot.hasDashboard &&
            await _storage.readPreference(_dashboardKey) != null,
        existingServices: List.unmodifiable(existingServices),
        requiresCertificateReview:
            (connections['proxmox'] as Map?)?['allowSelfSigned'] == 'true',
        requiresPrivacyReview:
            privacy?.reviewRequired ??
            (snapshot.hasDashboard || connections.containsKey('ha')),
        protectedEntityCount: privacy?.entityIds.length ?? 0,
      );
    } catch (_) {
      throw const BackupException(
        'storage_failed',
        'Existing settings could not be checked.',
      );
    }
  });

  /// Apply only selected groups. A connection is a complete record: an old
  /// endpoint is never combined with the imported endpoint's token/password.
  Future<void> restore(
    BackupSnapshot snapshot,
    BackupSelection selection, {
    BackupConflictPolicy conflictPolicy = BackupConflictPolicy.keepExisting,
  }) => ConfigurationWrites.run(() async {
    final json = snapshot.toJson();
    // Validate every group, including ones the user chose not to restore.
    validateBackupJson(json);
    final groups = json['groups'] as Map<String, dynamic>;
    if (selection.isEmpty ||
        !((selection.settings && snapshot.hasSettings) ||
            (selection.dashboard && snapshot.hasDashboard) ||
            (selection.connections && snapshot.hasConnections))) {
      throw const BackupValidationException(
        'Select a group contained in this backup.',
      );
    }
    await _requireRecovered();
    final changes = <_Change>[];
    final replace = conflictPolicy == BackupConflictPolicy.replaceSelected;
    try {
      final previousPrivacy = await _storage.readSecret(
        WellbeingDisclosureStore.storageKey,
      );
      final previousPolicy = WellbeingDisclosurePolicy.decode(previousPrivacy);
      final incoming = groups['privacy'] == null
          ? WellbeingDisclosurePolicy(
              reviewRequired:
                  (selection.dashboard && snapshot.hasDashboard) ||
                  (selection.connections &&
                      (groups['connections'] as Map?)?.containsKey('ha') ==
                          true),
            )
          : WellbeingDisclosurePolicy.fromJson(groups['privacy']);
      final combined = WellbeingDisclosurePolicy.fromJson(
        WellbeingDisclosurePolicy(
          entityIds: {...previousPolicy.entityIds, ...incoming.entityIds},
          reviewRequired:
              previousPolicy.reviewRequired || incoming.reviewRequired,
        ).toJson(),
      );
      if (jsonEncode(previousPolicy.toJson()) !=
          jsonEncode(combined.toJson())) {
        changes.add(
          _Change(
            true,
            WellbeingDisclosureStore.storageKey,
            previousPrivacy,
            jsonEncode(combined.toJson()),
          ),
        );
      }
      if (selection.settings && snapshot.hasSettings) {
        final settings = groups['settings'] as Map<String, dynamic>;
        // Older backups only contain the nightly schedule. Replacing those
        // settings must also retire a newer weekly override, in the same
        // rollback journal, so the imported schedule can take effect.
        if (replace &&
            !settings.containsKey(ScreenProgram.preferenceKey) &&
            const {
              'night_start_minutes',
              'night_end_minutes',
              'dim_brightness_at_night',
              'screen_off_at_night',
            }.any(settings.containsKey)) {
          final previous = await _storage.readPreference(
            ScreenProgram.preferenceKey,
          );
          if (previous != null) {
            changes.add(
              _Change(false, ScreenProgram.preferenceKey, previous, null),
            );
          }
        }
        for (final entry in settings.entries) {
          final previous = await _storage.readPreference(entry.key);
          if (!replace && previous != null) continue;
          // A restored door mapping never imports physical-control approval.
          final next =
              entry.key == DoorStation.storageKey && entry.value != null
              ? DoorStation.uncommissionStored(entry.value as String)
              : entry.value;
          changes.add(_Change(false, entry.key, previous, next));
          if (entry.key == 'enabled_services') {
            changes.add(
              _Change(
                false,
                _migrationKey,
                await _storage.readPreference(_migrationKey),
                true,
              ),
            );
          }
        }
      }
      if (selection.dashboard && snapshot.hasDashboard) {
        final previous = await _storage.readPreference(_dashboardKey);
        if (replace || previous == null) {
          changes.add(
            _Change(
              false,
              _dashboardKey,
              previous,
              jsonEncode(groups['dashboard']),
            ),
          );
        }
      }
      if (selection.connections && snapshot.hasConnections) {
        final records = groups['connections'] as Map<String, dynamic>;
        for (final record in records.entries) {
          if (!replace && await _hasConnection(record.key)) continue;
          final values = record.value as Map<String, dynamic>;
          for (final field in backupConnectionFields[record.key]!.entries) {
            final previous = await _storage.readSecret(field.value);
            // Restoring a vault never silently grants certificate exceptions.
            final next = field.key == 'allowSelfSigned'
                ? 'false'
                : values[field.key] as String;
            changes.add(_Change(true, field.value, previous, next));
          }
        }
      }
      if (changes.isEmpty) return;
      final journal = _encodeJournal(changes);
      // Persist rollback data before the first preference/credential mutation.
      await _storage.writeSecret(restoreJournalKey, journal);
    } on BackupException {
      rethrow;
    } catch (_) {
      throw const BackupException(
        'storage_failed',
        'Restore could not be prepared.',
      );
    }
    try {
      for (final change in changes) {
        await _write(change, previous: false);
      }
      // This is the commit point. A surviving journal means rollback on boot.
      await _storage.writeSecret(restoreJournalKey, null);
    } catch (_) {
      final complete = await _rollback(changes);
      throw BackupRestoreException(rollbackComplete: complete);
    }
  });

  /// Run before constructing configuration providers. If a restore was
  /// interrupted, put every affected value back before allowing app access.
  /// A failed recovery retains the journal for another recovery attempt.
  Future<bool> recoverPendingRestore() => ConfigurationWrites.run(() async {
    final String? raw;
    try {
      raw = await _storage.readSecret(restoreJournalKey);
    } catch (_) {
      throw const BackupRestoreException(rollbackComplete: false);
    }
    if (raw == null) return false;
    final changes = _decodeJournal(raw);
    if (!await _rollback(changes)) {
      throw const BackupRestoreException(rollbackComplete: false);
    }
    return true;
  });

  Future<void> _requireRecovered() async {
    try {
      if (await _storage.readSecret(restoreJournalKey) != null) {
        throw const BackupException(
          'recovery_required',
          'An interrupted restore needs recovery before continuing.',
        );
      }
    } on BackupException {
      rethrow;
    } catch (_) {
      throw const BackupException(
        'storage_failed',
        'Restore status could not be checked.',
      );
    }
  }

  Future<bool> _hasConnection(String service) async {
    for (final key in backupConnectionFields[service]!.values) {
      if (await _storage.readSecret(key) != null) return true;
    }
    return false;
  }

  Future<Map<String, dynamic>?> _readConnection(String service) async {
    final values = <String, dynamic>{};
    for (final field in backupConnectionFields[service]!.entries) {
      values[field.key] = await _storage.readSecret(field.value);
    }
    if (values.values.every((value) => value == null)) return null;
    if (service == 'proxmox') values['allowSelfSigned'] ??= 'true';
    if (values.values.any((value) => value == null)) {
      throw const BackupValidationException(
        'An incomplete connection could not be included.',
      );
    }
    return values;
  }

  Future<void> _write(_Change change, {required bool previous}) {
    final value = previous ? change.before : change.after;
    return change.secret
        ? _storage.writeSecret(change.key, value as String?)
        : _storage.writePreference(change.key, value);
  }

  Future<bool> _rollback(List<_Change> changes) async {
    var complete = true;
    for (final change in changes.reversed) {
      try {
        await _write(change, previous: true);
      } catch (_) {
        complete = false;
      }
    }
    if (complete) {
      try {
        await _storage.writeSecret(restoreJournalKey, null);
      } catch (_) {
        complete = false;
      }
    }
    return complete;
  }

  String _encodeJournal(List<_Change> changes) {
    final raw = jsonEncode({
      'version': 1,
      'changes': changes
          .map((c) => {'secret': c.secret, 'key': c.key, 'before': c.before})
          .toList(),
    });
    // The same validation is used before saving and before startup recovery.
    _decodeJournal(raw);
    return raw;
  }

  List<_Change> _decodeJournal(String raw) {
    try {
      if (utf8.encode(raw).length > _maxJournalBytes) {
        throw const FormatException();
      }
      final json = jsonDecode(raw);
      if (json is! Map ||
          json.length != 2 ||
          json['version'] != 1 ||
          json['changes'] is! List ||
          (json['changes'] as List).length > 100) {
        throw const FormatException();
      }
      final secretKeys =
          backupConnectionFields.values.expand((v) => v.values).toSet()
            ..add(WellbeingDisclosureStore.storageKey);
      final preferenceKeys = {
        ...backupPreferenceKeys,
        _dashboardKey,
        _migrationKey,
      };
      final seen = <String>{};
      return (json['changes'] as List).map((raw) {
        if (raw is! Map ||
            raw.length != 3 ||
            raw['secret'] is! bool ||
            raw['key'] is! String ||
            !raw.containsKey('before')) {
          throw const FormatException();
        }
        final secret = raw['secret'] as bool;
        final key = raw['key'] as String;
        if (!(secret ? secretKeys : preferenceKeys).contains(key) ||
            !seen.add('$secret:$key')) {
          throw const FormatException();
        }
        final value = raw['before'];
        if (secret &&
            value != null &&
            (value is! String ||
                value.length >
                    (key == WellbeingDisclosureStore.storageKey
                        ? 70000
                        : 16384))) {
          throw const FormatException();
        }
        if (!secret &&
            value != null &&
            value is! bool &&
            value is! int &&
            value is! String &&
            !(value is List &&
                value.length <= 10000 &&
                value.every((v) => v is String))) {
          throw const FormatException();
        }
        return _Change(secret, key, value, null);
      }).toList();
    } catch (_) {
      throw const BackupException(
        'recovery_required',
        'Restore recovery data is invalid. It was preserved for recovery.',
      );
    }
  }
}

class _Change {
  const _Change(this.secret, this.key, this.before, this.after);
  final bool secret;
  final String key;
  final Object? before;
  final Object? after;
}
