import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import 'core_audit_api.dart';
import 'core_audit_checkpoint_store.dart';
import '../domain/core_audit_models.dart';

final class CoreAuditController extends ChangeNotifier {
  CoreAuditController(this.account, this.checkpointStore) {
    account.addListener(_accountChanged);
    scheduleMicrotask(_accountChanged);
  }

  final ServerAccountController account;
  final CoreAuditCheckpointStore checkpointStore;

  CoreAuditVerification? verification;
  CoreAuditTrustedCheckpoint? trustedCheckpoint;
  String? failure, checkpointFailure, checkpointAlarm;
  bool busy = false, loaded = false, trustedCompared = false;

  bool _disposed = false, _attempted = false;
  int _epoch = 0;
  Object? _boundIdentity;

  ServerSession? get _ready {
    final session = account.session;
    if (_disposed ||
        !account.initialized ||
        account.working ||
        account.hasPendingContext ||
        session == null ||
        session.context == null ||
        session.authMutationPending ||
        !session.user.canAdminister) {
      return null;
    }
    return session;
  }

  bool get available => _ready != null;
  bool get canRefresh => available && !busy;
  bool get canPin =>
      canRefresh &&
      loaded &&
      trustedCheckpoint == null &&
      verification != null &&
      !verification!.comparedCheckpoint &&
      checkpointFailure == null &&
      checkpointAlarm == null;
  bool get canRotate =>
      canRefresh &&
      trustedCompared &&
      trustedCheckpoint != null &&
      verification != null &&
      verification!.checkpoint != trustedCheckpoint!.checkpoint &&
      checkpointFailure == null &&
      checkpointAlarm == null;

  Object? _identity(ServerSession? session) => session == null
      ? null
      : Object.hash(
          session.endpoint.baseUrl,
          session.user.id,
          session.context,
          account.generation,
        );

  bool _same(ServerSession original, int generation) {
    final active = _ready;
    return !_disposed &&
        account.isCurrent(generation) &&
        active != null &&
        active.endpoint.baseUrl == original.endpoint.baseUrl &&
        active.user.id == original.user.id &&
        active.context == original.context;
  }

  void _clear() {
    verification = null;
    trustedCheckpoint = null;
    failure = null;
    checkpointFailure = null;
    checkpointAlarm = null;
    busy = false;
    loaded = false;
    trustedCompared = false;
  }

  void _accountChanged() {
    if (_disposed) return;
    final identity = _identity(_ready);
    if (identity != _boundIdentity) {
      _epoch++;
      _boundIdentity = identity;
      _attempted = false;
      _clear();
    }
    notifyListeners();
    if (identity != null && !_attempted) {
      _attempted = true;
      unawaited(refresh());
    }
  }

  String _code(Object error) => switch (error) {
    LarenorServerException value => value.code,
    CoreAuditCheckpointException value => value.code,
    _ => 'connection_failed',
  };

  Future<void> refresh() async {
    final original = _ready;
    if (original == null || busy) return;
    final context = original.context!;
    final generation = account.generation;
    final operation = ++_epoch;
    bool current() => _epoch == operation && _same(original, generation);
    busy = true;
    failure = null;
    checkpointFailure = null;
    checkpointAlarm = null;
    notifyListeners();
    try {
      CoreAuditTrustedCheckpoint? retained;
      try {
        retained = await checkpointStore.read(context, isCurrent: current);
      } on CoreAuditCheckpointException catch (error) {
        checkpointFailure = error.code;
      }
      if (!current()) throw const LarenorServerException('cancelled');
      if (checkpointFailure == null) {
        try {
          final proof = await account.withSession((api, session) async {
            if (!current() || session.context != context) {
              throw const LarenorServerException('cancelled');
            }
            return CoreAuditApi(
              api,
              session.accessToken,
              context,
            ).verification(checkpoint: retained?.checkpoint);
          });
          if (!current()) throw const LarenorServerException('cancelled');
          if (retained != null &&
              (proof.chainId != retained.chainId ||
                  proof.sequence < retained.sequence)) {
            checkpointAlarm = proof.sequence < retained.sequence
                ? 'rollback'
                : 'mismatch';
            verification = null;
            trustedCompared = false;
          } else {
            verification = proof;
            trustedCompared = retained != null;
          }
        } catch (error) {
          if (!current()) throw const LarenorServerException('cancelled');
          final code = _code(error);
          if (retained != null &&
              {'revision_conflict', 'invalid_response'}.contains(code)) {
            checkpointAlarm = 'mismatch';
          } else {
            failure = code;
          }
          verification = null;
          trustedCompared = false;
        }
      }
      if (!current()) throw const LarenorServerException('cancelled');
      trustedCheckpoint = retained;
      loaded = true;
    } catch (error) {
      if (current() && _code(error) != 'cancelled') failure = _code(error);
    } finally {
      if (!_disposed && _epoch == operation) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> pinCurrent() async {
    final original = _ready, proof = verification;
    if (!canPin || original == null || proof == null) return;
    final context = original.context!, generation = account.generation;
    final operation = ++_epoch;
    bool current() => _epoch == operation && _same(original, generation);
    busy = true;
    checkpointFailure = null;
    notifyListeners();
    try {
      trustedCheckpoint = await checkpointStore.pin(
        context,
        proof,
        isCurrent: current,
      );
      if (!current()) throw const LarenorServerException('cancelled');
      trustedCompared = false;
    } catch (error) {
      if (current()) checkpointFailure = _code(error);
    } finally {
      if (!_disposed && _epoch == operation) {
        busy = false;
        notifyListeners();
      }
    }
    if (!_disposed && trustedCheckpoint != null) await refresh();
  }

  Future<void> rotateTrusted() async {
    final original = _ready, before = trustedCheckpoint, proof = verification;
    if (!canRotate || original == null || before == null || proof == null) {
      return;
    }
    final context = original.context!, generation = account.generation;
    final operation = ++_epoch;
    bool current() => _epoch == operation && _same(original, generation);
    busy = true;
    checkpointFailure = null;
    notifyListeners();
    try {
      trustedCheckpoint = await checkpointStore.rotate(
        context,
        before,
        proof,
        isCurrent: current,
      );
      if (!current()) throw const LarenorServerException('cancelled');
      trustedCompared = false;
    } catch (error) {
      if (current()) checkpointFailure = _code(error);
    } finally {
      if (!_disposed && _epoch == operation) {
        busy = false;
        notifyListeners();
      }
    }
    if (!_disposed && trustedCheckpoint != null) await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
