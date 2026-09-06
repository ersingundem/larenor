import 'dart:async';

import '../../backup/data/backup_repository.dart';
import '../../backup/data/backup_restore_access.dart';
import '../../backup/data/backup_snapshot.dart';
import '../domain/server_models.dart';
import 'server_account_controller.dart';

enum ServerVaultDirection { upload, restore }

/// Review metadata contains only counts, fixed service IDs and a revision.
/// The configuration document remains private to this controller.
class ServerVaultReview {
  ServerVaultReview._({
    required this.direction,
    required this.revision,
    required this.local,
    required this.remote,
    required this.selection,
    required this.conflictPolicy,
    required this.createdAt,
  });
  final ServerVaultDirection direction;
  final int revision;
  final BackupPreview local;
  final BackupPreview? remote;
  final BackupSelection selection;
  final BackupConflictPolicy conflictPolicy;
  final DateTime createdAt;
}

class _VaultIntent {
  _VaultIntent(this.review, this.snapshot, this.epoch, this.prepared);
  final ServerVaultReview review;
  final BackupSnapshot snapshot;
  final int epoch;
  final PreparedBackupRestore? prepared;
}

/// One visible, unlocked route, bound to one authenticated Server account.
/// Network reads never restore local configuration. Writes have no retry path.
class ServerVaultController {
  ServerVaultController({
    required ServerAccountController account,
    required this._repository,
    required this._isCurrent,
    DateTime Function()? clock,
  }) : _account = account,
       _clock = clock ?? DateTime.now,
       _accountGeneration = account.generation {
    _account.addListener(_accountChanged);
  }

  final ServerAccountController _account;
  final BackupRepository _repository;
  final bool Function() _isCurrent;
  final DateTime Function() _clock;
  final int _accountGeneration;
  _VaultIntent? _intent;
  int _epoch = 0;
  bool _disposed = false;
  bool _busy = false;
  bool get busy => _busy;

  bool get available =>
      !_disposed &&
      _account.isCurrent(_accountGeneration) &&
      _account.initialized &&
      !_account.working &&
      _account.session != null &&
      !_account.session!.user.mustChangePassword &&
      _isCurrent();

  void _accountChanged() {
    if (!_account.isCurrent(_accountGeneration) ||
        _account.working ||
        _account.session == null ||
        _account.session!.user.mustChangePassword) {
      invalidate();
    }
  }

  /// Cancels authorization, not a request already accepted by the server.
  /// An outstanding response may still arrive but cannot repopulate the review.
  void invalidate() {
    _epoch++;
    _intent?.prepared?.retire();
    _intent = null;
  }

  void dispose() {
    if (_disposed) return;
    _account.removeListener(_accountChanged);
    invalidate();
    _disposed = true;
  }

  void _check(int epoch) {
    if (!available || epoch != _epoch) {
      throw const LarenorServerException('cancelled');
    }
  }

  void _begin() {
    if (_busy) throw const LarenorServerException('busy');
    _check(_epoch);
    _busy = true;
  }

  Future<ServerVault> _readVault(int epoch, {ServerVaultReview? review}) =>
      _account.withSession((api, session) async {
        _check(epoch);
        if (review != null) _checkDeadline(review);
        try {
          final value = await api.readVault(session.accessToken);
          _check(epoch);
          if (review != null) _checkDeadline(review);
          return value;
        } catch (_) {
          // Retired route responses cannot reject a still-current account.
          // Active unauthorized responses retain the account's normal handling.
          _check(epoch);
          if (review != null) _checkDeadline(review);
          rethrow;
        }
      });

  BackupSnapshot _validated(BackupSnapshot snapshot) {
    // File backups retain v1 compatibility; Server migration must carry the
    // mandatory v2 privacy policy. Never weaken that boundary for a test fake.
    return ServerVault.fromJson({
      'revision': 0,
      'document': {'version': 1, 'snapshot': snapshot.toJson()},
    }).snapshot!;
  }

  Future<ServerVaultReview> prepare({
    required ServerVaultDirection direction,
    required BackupSelection selection,
    BackupConflictPolicy conflictPolicy = BackupConflictPolicy.keepExisting,
    BackupRestoreAccess? access,
  }) async {
    _begin();
    invalidate();
    final epoch = _epoch;
    PreparedBackupRestore? prepared;
    try {
      if (selection.isEmpty) {
        throw const LarenorServerException('empty_selection');
      }
      final vault = await _readVault(epoch);
      _check(epoch);
      final remote = vault.snapshot == null
          ? null
          : _validated(vault.snapshot!);
      if (direction == ServerVaultDirection.restore && remote == null) {
        throw const LarenorServerException('empty_vault');
      }
      final selected = direction == ServerVaultDirection.restore
          ? BackupSelection(
              settings: selection.settings && remote!.hasSettings,
              dashboard: selection.dashboard && remote!.hasDashboard,
              connections: selection.connections && remote!.hasConnections,
            )
          : selection;
      if (selected.isEmpty) {
        throw const LarenorServerException('empty_selection');
      }
      if (direction == ServerVaultDirection.restore) {
        if (access == null) {
          throw const BackupException(
            'restore_expired',
            'Read the restore preview again.',
          );
        }
        prepared = await _repository.prepareRestore(
          remote!,
          selected,
          conflictPolicy: conflictPolicy,
          access: access,
        );
        _check(epoch);
      }
      final local = _validated(await _repository.capture(selected));
      _check(epoch);
      final localPreview = await _repository.preview(local);
      _check(epoch);
      final remotePreview = remote == null
          ? null
          : await _repository.preview(remote);
      _check(epoch);
      final review = ServerVaultReview._(
        direction: direction,
        revision: vault.revision,
        local: localPreview,
        remote: remotePreview,
        selection: selected,
        conflictPolicy: conflictPolicy,
        createdAt: _clock(),
      );
      _intent = _VaultIntent(
        review,
        direction == ServerVaultDirection.upload ? local : remote!,
        epoch,
        prepared,
      );
      return review;
    } catch (_) {
      prepared?.retire();
      rethrow;
    } finally {
      _busy = false;
    }
  }

  _VaultIntent _take(ServerVaultReview review, ServerVaultDirection direction) {
    _check(_epoch);
    final intent = _intent;
    _intent = null; // Even expired or rejected confirmation cannot be reused.
    if (intent == null ||
        !identical(intent.review, review) ||
        review.direction != direction ||
        intent.epoch != _epoch) {
      throw const LarenorServerException('cancelled');
    }
    try {
      _checkDeadline(review);
    } catch (_) {
      intent.prepared?.retire();
      rethrow;
    }
    return intent;
  }

  void _checkDeadline(ServerVaultReview review) {
    final age = _clock().difference(review.createdAt);
    if (age.isNegative || age >= const Duration(minutes: 5)) {
      throw const LarenorServerException('review_expired');
    }
  }

  Future<void> upload(ServerVaultReview review) async {
    _begin();
    try {
      final intent = _take(review, ServerVaultDirection.upload);
      await _account.withSession((api, session) {
        _check(intent.epoch);
        _checkDeadline(review);
        return api.writeVault(
          accessToken: session.accessToken,
          expectedRevision: review.revision,
          snapshot: intent.snapshot,
        );
      });
      _check(intent.epoch);
    } finally {
      _busy = false;
    }
  }

  /// Rechecks the server revision before handing a prepared local restore to
  /// ConfigurationScope. That boundary intentionally disposes this controller
  /// before execution; the capability retains its separate durable checks.
  Future<PreparedBackupRestore> takeRestore(ServerVaultReview review) async {
    _begin();
    PreparedBackupRestore? prepared;
    try {
      final intent = _take(review, ServerVaultDirection.restore);
      prepared = intent.prepared;
      if (prepared == null) throw const LarenorServerException('cancelled');
      final current = await _readVault(intent.epoch, review: review);
      _check(intent.epoch);
      _checkDeadline(review);
      if (current.revision != review.revision || current.snapshot == null) {
        throw const LarenorServerException('conflict');
      }
      _validated(current.snapshot!);
      await prepared.checkBeforeHandoff();
      _check(intent.epoch);
      _checkDeadline(review);
      return prepared;
    } catch (_) {
      prepared?.retire();
      rethrow;
    } finally {
      _busy = false;
    }
  }
}
