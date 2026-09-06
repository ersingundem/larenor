import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../home_scope/data/home_layout_access.dart';
import '../../server/data/server_session_store.dart';
import '../../settings/data/pin_lock_store.dart';
import 'backup_restore_access.dart';
import 'backup_snapshot.dart';

Never _unavailable() => throw const BackupException(
  'restore_expired',
  'Read the restore preview again.',
);
String _fingerprint(String value) =>
    sha256.convert(utf8.encode(value)).toString();

/// Captures authority from the live runtime. Its durable half deliberately does
/// not consult providers after ConfigurationScope has disposed that runtime.
abstract final class CapturedRestoreAccess {
  static Future<BackupRestoreAccess> capture({
    required HomeSessionController? home,
    required HomeSourcePersistence sourceStore,
    required ServerSessionPersistence sessionStore,
    required PinLockStore pinStore,
    required String? expectedPin,
    required bool Function() isCurrent,
    DateTime Function()? clock,
  }) async {
    try {
      if (!isCurrent()) _unavailable();
      final now = clock ?? DateTime.now;
      final source = home == null ? await sourceStore.read() : home.source;
      if (!isCurrent() ||
          source == null ||
          home != null &&
              (home.busy || home.failure != null || !home.interaction.active)) {
        _unavailable();
      }
      final layout = source == HomeSource.verifiedCore
          ? homeLayoutAccess(home, clock: now)
          : null;
      if (source == HomeSource.verifiedCore && layout == null) _unavailable();
      final epoch = home?.interaction.epoch;
      final identity = home?.runtimeIdentity;
      final access = _CapturedRestoreAccess(
        source,
        sourceStore,
        sessionStore,
        pinStore,
        expectedPin,
        isCurrent,
        () =>
            home == null ||
            home.source == source &&
                !home.busy &&
                home.failure == null &&
                home.interaction.active &&
                home.interaction.epoch == epoch &&
                home.runtimeIdentity == identity &&
                (layout?.isCurrent ?? true),
        layout == null
            ? null
            : {
                'coreId': layout.scope.coreId,
                'homeId': layout.scope.homeId,
                'userId': layout.scope.userId,
              },
        layout == null
            ? null
            : _fingerprint(home!.account.session!.encodeStorage()),
        layout?.validUntil ?? now().toUtc().add(const Duration(minutes: 5)),
        now,
      );
      access.checkLive();
      await access.checkDurable();
      access.checkLive();
      return access;
    } on BackupException {
      rethrow;
    } catch (_) {
      _unavailable();
    }
  }
}

final class _CapturedRestoreAccess implements BackupRestoreAccess {
  _CapturedRestoreAccess(
    this.source,
    this._sourceStore,
    this._sessionStore,
    this._pinStore,
    this._pin,
    this._current,
    this._runtime,
    Map<String, dynamic>? scope,
    this._sessionDigest,
    this.validUntil,
    this._clock,
  ) : _scope = scope == null ? null : Map.unmodifiable(scope);
  @override
  final HomeSource source;
  final HomeSourcePersistence _sourceStore;
  final ServerSessionPersistence _sessionStore;
  final PinLockStore _pinStore;
  final String? _pin, _sessionDigest;
  final bool Function() _current, _runtime;
  final Map<String, dynamic>? _scope;
  @override
  final DateTime validUntil;
  final DateTime Function() _clock;
  bool _retired = false;
  @override
  Map<String, dynamic> get ownership => Map.unmodifiable({
    'source': source.name,
    if (_scope != null) 'scope': _scope,
  });
  @override
  void checkLive() {
    if (_retired) _unavailable();
    if (!_current() || !_runtime() || !_clock().toUtc().isBefore(validUntil)) {
      _retired = true;
      _unavailable();
    }
  }

  @override
  Future<void> checkDurable() async {
    try {
      if (!_clock().toUtc().isBefore(validUntil)) _unavailable();
      if (await _sourceStore.read() != source) _unavailable();
      if (await _pinStore.read() != _pin) _unavailable();
      if (_sessionDigest != null) {
        final session = await _sessionStore.read();
        if (session == null ||
            session.authMutationPending ||
            session.user.mustChangePassword ||
            session.expiresSoon(_clock()) ||
            _fingerprint(session.encodeStorage()) != _sessionDigest) {
          _unavailable();
        }
      }
      if (!_clock().toUtc().isBefore(validUntil)) _unavailable();
    } on BackupException {
      rethrow;
    } catch (_) {
      _unavailable();
    }
  }

  @override
  String toString() => 'CapturedRestoreAccess';
}
