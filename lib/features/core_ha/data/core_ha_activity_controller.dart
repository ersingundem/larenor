import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/core_ha_activity_models.dart';
import 'core_ha_api.dart';
import 'core_ha_checkpoint_store.dart';

/// Read-only, route-owned history. It never dispatches or replays a command.
class CoreHaActivityController extends ChangeNotifier {
  CoreHaActivityController(
    this.home,
    this.target,
    this.factory,
    this.clock,
    this.current,
    this.owner, {
    required this.verifyIntegrity,
    required this.checkpointStore,
    required this.checkpointProtected,
    this.pageSize = 25,
  }) {
    home?.addListener(_changed);
    home?.interaction.addListener(_changed);
    home?.account.addListener(_changed);
    owner.addListener(_changed);
  }

  final HomeSessionController? home;
  final HomeResourceRecord target;
  final ServerApiFactory factory;
  final DateTime Function() clock;
  final bool Function() current;
  final Listenable owner;
  final bool verifyIntegrity;
  final CoreHaCheckpointStore checkpointStore;
  final bool checkpointProtected;
  final int pageSize;

  List<CoreHaHistoryEntry> entries = const [];
  CoreHaHistoryVerification? verification;
  CoreHaTrustedCheckpoint? trustedCheckpoint;
  String? nextBefore, failure, integrityFailure, checkpointFailure;
  String? checkpointAlarm;
  bool busy = false, loaded = false, stale = false, truncated = false;
  bool checkpointLoaded = false, trustedCompared = false;
  bool _disposed = false,
      _visible = false,
      _attempted = false,
      _preparing = false;
  bool Function()? _preparationCurrent;
  int _epoch = 0;
  LarenorServerApi? _transport;
  ServerSession? _bound;
  Timer? _expiry;

  bool get _sourceCurrent {
    try {
      return !_disposed &&
          _visible &&
          current() &&
          home != null &&
          target.kind == HomeResourceKind.resource &&
          home!.source == HomeSource.verifiedCore &&
          !home!.busy &&
          home!.failure == null &&
          home!.interaction.active;
    } catch (_) {
      return false;
    }
  }

  ServerSession? get _ready {
    final account = home?.account, session = account?.session;
    if (!_sourceCurrent ||
        account == null ||
        !account.initialized ||
        account.working ||
        account.hasPendingContext ||
        session == null ||
        session.context != target.context ||
        session.authMutationPending ||
        session.user.mustChangePassword ||
        verifyIntegrity && !session.user.canAdminister) {
      return null;
    }
    return session;
  }

  bool get fresh => _ready != null && !_ready!.expiresSoon(clock());
  bool get canRefresh => fresh && !busy;
  bool get canLoadMore =>
      fresh &&
      !busy &&
      !truncated &&
      nextBefore != null &&
      entries.length < CoreHaHistoryPage.maximumVisibleEntries;
  bool get canVerifyCheckpoint => verifyIntegrity && fresh && !busy;
  bool get canPinCheckpoint =>
      checkpointProtected &&
      checkpointLoaded &&
      trustedCheckpoint == null &&
      verification != null &&
      !verification!.comparedCheckpoint &&
      checkpointAlarm == null &&
      checkpointFailure == null &&
      fresh &&
      !busy;
  bool get canRotateCheckpoint =>
      checkpointProtected &&
      trustedCompared &&
      trustedCheckpoint != null &&
      verification != null &&
      verification!.checkpoint != trustedCheckpoint!.checkpoint &&
      checkpointAlarm == null &&
      checkpointFailure == null &&
      fresh &&
      !busy;

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _clear() {
    entries = const [];
    verification = null;
    trustedCheckpoint = null;
    nextBefore = null;
    failure = null;
    integrityFailure = null;
    checkpointFailure = null;
    checkpointAlarm = null;
    loaded = false;
    stale = false;
    truncated = false;
    checkpointLoaded = false;
    trustedCompared = false;
  }

  void _retire() {
    _epoch++;
    busy = false;
    _preparing = false;
    _preparationCurrent = null;
    _transport?.close();
    _transport = null;
    _expiry?.cancel();
    _expiry = null;
    _bound = null;
    _clear();
  }

  void setVisible(bool value) {
    if (_disposed || value == _visible) return;
    _visible = value;
    _retire();
    _attempted = false;
    _emit();
    _start();
  }

  void _start() {
    if (!_attempted && fresh) {
      _attempted = true;
      unawaited(refresh());
    }
  }

  void _changed() {
    if (_disposed) return;
    if (_preparing && (_preparationCurrent?.call() ?? false)) {
      _emit();
      return;
    }
    if (!fresh || _bound != null && !identical(_bound, _ready)) {
      _retire();
      _attempted = false;
    }
    _emit();
    _start();
  }

  Future<T> _session<T>(
    int operation,
    Future<T> Function(CoreHaApi api) action,
  ) async {
    final original = _ready;
    if (original == null) throw const LarenorServerException('cancelled');
    final generation = home!.account.generation,
        interactionEpoch = home!.interaction.epoch;
    bool live() =>
        !_disposed &&
        _epoch == operation &&
        _sourceCurrent &&
        home!.interaction.epoch == interactionEpoch &&
        home!.account.isCurrent(generation);
    bool sameScope(ServerSession session) =>
        session.context == original.context &&
        session.user.id == original.user.id &&
        session.endpoint.baseUrl == original.endpoint.baseUrl;
    late T result;
    _preparing = true;
    _preparationCurrent = live;
    await home!.account.withSession((_, session) async {
      if (!live() || !sameScope(session) || !fresh) {
        throw const LarenorServerException('cancelled');
      }
      _preparing = false;
      _bound = session;
      _expiry?.cancel();
      final remaining = session.expiresAt
          .subtract(const Duration(seconds: 30))
          .difference(clock());
      _expiry = Timer(
        remaining.isNegative ? Duration.zero : remaining,
        _changed,
      );
      _transport?.close();
      _transport = factory(session.endpoint);
      bool authoritative() => live() && identical(_ready, session) && fresh;
      try {
        result = await action(
          CoreHaApi(
            _transport!,
            session.accessToken,
            target,
            isCurrent: authoritative,
          ),
        );
      } catch (_) {
        if (!authoritative()) {
          throw const LarenorServerException('cancelled');
        }
        rethrow;
      }
      if (!authoritative()) throw const LarenorServerException('cancelled');
    });
    if (!live() || !fresh) throw const LarenorServerException('cancelled');
    return result;
  }

  String _failure(Object error) =>
      error is LarenorServerException ? error.code : 'connection_failed';

  Future<void> refresh() => _load(more: false);
  Future<void> loadMore() => _load(more: true);

  Future<void> _load({required bool more}) async {
    if (!canRefresh || more && !canLoadMore) return;
    final operation = ++_epoch,
        oldEntries = entries,
        oldVerification = verification,
        oldTrusted = trustedCheckpoint,
        oldCheckpointLoaded = checkpointLoaded,
        oldTrustedCompared = trustedCompared,
        oldCheckpointFailure = checkpointFailure,
        oldCheckpointAlarm = checkpointAlarm,
        cursor = more ? nextBefore : null;
    busy = true;
    failure = null;
    integrityFailure = null;
    if (!more) {
      checkpointFailure = null;
      checkpointAlarm = null;
    }
    _attempted = true;
    _emit();
    try {
      final page = await _session(
        operation,
        (api) => api.history(before: cursor, limit: pageSize),
      );
      CoreHaHistoryVerification? proof = oldVerification;
      String? proofFailure;
      var pin = oldTrusted;
      var pinLoaded = oldCheckpointLoaded;
      var comparedTrusted = more ? oldTrustedCompared : false;
      String? pinFailure = more ? oldCheckpointFailure : null;
      String? alarm = more ? oldCheckpointAlarm : null;
      if (!more && verifyIntegrity) {
        if (checkpointProtected) {
          try {
            pin = await checkpointStore.read(
              target.context,
              isCurrent: () => _epoch == operation && _sourceCurrent,
            );
            pinLoaded = true;
          } on CoreHaCheckpointException catch (error) {
            pinFailure = error.code;
          }
        } else {
          pin = null;
          pinLoaded = false;
        }
        if (pinFailure == null) {
          try {
            final verified = await _session(
              operation,
              (api) => api.verifyHistory(checkpoint: pin?.checkpoint),
            );
            proof = verified;
            if (pin != null) {
              comparedTrusted = true;
              if (verified.chainId != pin.chainId) {
                proof = null;
                comparedTrusted = false;
                alarm = 'mismatch';
              } else if (verified.sequence < pin.sequence) {
                proof = null;
                comparedTrusted = false;
                alarm = 'rollback';
              }
            }
          } catch (error) {
            proof = null;
            proofFailure = _failure(error);
            if (pin != null &&
                {'conflict', 'revision_conflict'}.contains(proofFailure)) {
              alarm = 'mismatch';
            }
          }
        }
      }
      final combined = more ? [...oldEntries, ...page.entries] : page.entries;
      final ids = <String>{};
      if (combined.any((entry) => !ids.add(entry.receipt.requestId))) {
        throw const LarenorServerException('invalid_response');
      }
      if (more && oldEntries.isNotEmpty && page.entries.isNotEmpty) {
        final older = page.entries.first.receipt;
        final newer = oldEntries.last.receipt;
        final order = newer.createdAt.compareTo(older.createdAt);
        if (order < 0 ||
            order == 0 && newer.requestId.compareTo(older.requestId) <= 0) {
          throw const LarenorServerException('invalid_response');
        }
      }
      final cap = CoreHaHistoryPage.maximumVisibleEntries;
      if (combined.length > cap) {
        throw const LarenorServerException('invalid_response');
      }
      entries = List.unmodifiable(combined);
      verification = proof;
      integrityFailure = proofFailure;
      trustedCheckpoint = pin;
      checkpointLoaded = pinLoaded;
      trustedCompared = comparedTrusted;
      checkpointFailure = pinFailure;
      checkpointAlarm = alarm;
      nextBefore = page.nextBefore;
      truncated = combined.length == cap && page.nextBefore != null;
      if (truncated) nextBefore = null;
      loaded = true;
      stale = false;
    } catch (error) {
      if (_epoch == operation && _sourceCurrent) {
        entries = oldEntries;
        verification = oldVerification;
        trustedCheckpoint = oldTrusted;
        checkpointLoaded = oldCheckpointLoaded;
        trustedCompared = oldTrustedCompared;
        checkpointFailure = oldCheckpointFailure;
        checkpointAlarm = oldCheckpointAlarm;
        failure = _failure(error);
        stale = oldEntries.isNotEmpty;
        loaded = oldEntries.isNotEmpty;
      }
    } finally {
      if (!_disposed && _epoch == operation) {
        _transport?.close();
        _transport = null;
        _preparing = false;
        _preparationCurrent = null;
        busy = false;
        _emit();
      }
    }
  }

  Future<void> compareCheckpoint(String checkpoint) async {
    if (!canVerifyCheckpoint) return;
    final value = checkpoint.trim();
    if (value.isEmpty || value.length > 512) {
      integrityFailure = 'invalid_request';
      _emit();
      return;
    }
    final operation = ++_epoch;
    busy = true;
    integrityFailure = null;
    _emit();
    try {
      verification = await _session(
        operation,
        (api) => api.verifyHistory(checkpoint: value),
      );
      trustedCompared = false;
    } catch (error) {
      if (_epoch == operation && _sourceCurrent) {
        integrityFailure = _failure(error);
      }
    } finally {
      if (!_disposed && _epoch == operation) {
        _transport?.close();
        _transport = null;
        _preparing = false;
        _preparationCurrent = null;
        busy = false;
        _emit();
      }
    }
  }

  String _checkpointFailure(Object error) =>
      error is CoreHaCheckpointException ? error.code : 'write_failed';

  Future<void> pinCurrentCheckpoint() async {
    final proof = verification;
    if (!canPinCheckpoint || proof == null) return;
    final operation = ++_epoch;
    busy = true;
    checkpointFailure = null;
    _emit();
    try {
      trustedCheckpoint = await checkpointStore.pin(
        target.context,
        proof,
        isCurrent: () =>
            _epoch == operation && _sourceCurrent && checkpointProtected,
      );
      checkpointLoaded = true;
      trustedCompared = false;
    } catch (error) {
      if (_epoch == operation && _sourceCurrent) {
        checkpointFailure = _checkpointFailure(error);
      }
    } finally {
      if (!_disposed && _epoch == operation) {
        busy = false;
        _emit();
      }
    }
  }

  Future<void> rotateTrustedCheckpoint() async {
    final before = trustedCheckpoint, proof = verification;
    if (!canRotateCheckpoint || before == null || proof == null) return;
    final operation = ++_epoch;
    busy = true;
    checkpointFailure = null;
    _emit();
    try {
      trustedCheckpoint = await checkpointStore.rotate(
        target.context,
        before,
        proof,
        isCurrent: () =>
            _epoch == operation && _sourceCurrent && checkpointProtected,
      );
      trustedCompared = false;
    } catch (error) {
      if (_epoch == operation && _sourceCurrent) {
        checkpointFailure = _checkpointFailure(error);
      }
    } finally {
      if (!_disposed && _epoch == operation) {
        busy = false;
        _emit();
      }
    }
  }

  @override
  void dispose() {
    home?.removeListener(_changed);
    home?.interaction.removeListener(_changed);
    home?.account.removeListener(_changed);
    owner.removeListener(_changed);
    _retire();
    _disposed = true;
    super.dispose();
  }
}
