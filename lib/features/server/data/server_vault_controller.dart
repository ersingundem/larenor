import 'dart:async';

import '../../backup/data/backup_repository.dart';
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
  _VaultIntent(this.review, this.snapshot, this.epoch);
  final ServerVaultReview review;
  final BackupSnapshot snapshot;
  final int epoch;
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
  }) async {
    _begin();
    invalidate();
    final epoch = _epoch;
    try {
      if (selection.isEmpty) {
        throw const LarenorServerException('empty_selection');
      }
      final vault = await _account.withSession((api, session) {
        _check(epoch); // An awaited token refresh is not permission to send.
        return api.readVault(session.accessToken);
      });
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
      );
      return review;
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
    _checkDeadline(review);
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

  /// Rechecks the server revision before handing a local-only operation to
  /// ConfigurationScope. That boundary intentionally disposes this controller
  /// before execution; the closure must not access old providers or sessions.
  Future<Future<void> Function()> takeRestore(ServerVaultReview review) async {
    _begin();
    try {
      final intent = _take(review, ServerVaultDirection.restore);
      final current = await _account.withSession((api, session) {
        _check(intent.epoch);
        _checkDeadline(review);
        return api.readVault(session.accessToken);
      });
      _check(intent.epoch);
      _checkDeadline(review);
      if (current.revision != review.revision || current.snapshot == null) {
        throw const LarenorServerException('conflict');
      }
      _validated(current.snapshot!);
      final repository = _repository;
      final snapshot = intent.snapshot;
      final selection = review.selection;
      final policy = review.conflictPolicy;
      var consumed = false;
      return () async {
        if (consumed) throw const LarenorServerException('cancelled');
        consumed = true;
        await repository.restore(snapshot, selection, conflictPolicy: policy);
      };
    } finally {
      _busy = false;
    }
  }
}
